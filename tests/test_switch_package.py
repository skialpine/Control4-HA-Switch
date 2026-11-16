"""The real Switch artifact must preserve existing installation contracts."""

import xml.etree.ElementTree as ET
import zipfile

from tools.build_switch import PACKAGE_FILES, ROOT, build


def test_actual_switch_package_is_deterministic_and_has_only_runtime_files(tmp_path):
    first, second = tmp_path / "HA.Switch.c4z", tmp_path / "second.c4z"
    assert build(first) == build(second)
    assert first.read_bytes() == second.read_bytes()
    with zipfile.ZipFile(first) as package:
        names = package.namelist()
        assert len(names) == len(set(names))
        assert set(names) == set(PACKAGE_FILES)
        assert not any(part in name.lower() for name in names for part in ("proof", "test", "custom_components", "ha_gesture_bridge/"))
        for name in names:
            assert package.read(name) == (ROOT / name).read_bytes()
        xml = ET.fromstring(package.read("driver.xml"))
        assert xml.find("./config/script").get("file") in names
        assert xml.findtext("name") == xml.findtext("model") == "HA Switch"
        assert xml.findtext("version") == "107"
        assert xml.findtext("proxy") == "other"


def test_switch_xml_preserves_bindings_defaults_and_programming_commands():
    xml = ET.parse(ROOT / "driver.xml").getroot()
    connections = {entry.findtext("id"): entry for entry in xml.findall("./connections/connection")}
    assert set(connections) == {"999", "1", "200", "201", "202"}
    expected = {
        "999": ("1", "1", "HA_DEVICE", "true"),
        "1": ("1", "1", "RELAY", "false"),
        "200": ("6", "1", "BUTTON_LINK", "false"),
        "201": ("6", "1", "BUTTON_LINK", "false"),
        "202": ("6", "1", "BUTTON_LINK", "false"),
    }
    for identifier, (facing, kind, classname, consumer) in expected.items():
        connection = connections[identifier]
        assert connection.findtext("facing") == facing
        assert connection.findtext("type") == kind
        assert connection.findtext("./classes/class/classname") == classname
        assert connection.findtext("consumer").lower() == consumer
    properties = {entry.findtext("name"): entry for entry in xml.findall("./config/properties/property")}
    assert properties["Entity ID"].findtext("default") == "switch.bedroom_sleep_fan"
    assert properties["Operation Mode"].findtext("default") == "Control HA Device"
    assert [item.text for item in properties["Operation Mode"].findall("./items/item")] == ["Control HA Device", "Control HA Device with Button Events", "Programming Events Only"]
    assert properties["Entity Selection"].findtext("default") == "Manual Entity ID"
    assert properties["Debug Mode"].findtext("default") == "Off"
    assert properties["LED Behavior"].findtext("default") == "Use Device Setting"
    assert not {"LED Indicator", "LED On Color", "LED Off Color"} & properties.keys()
    for name in ("Driver Version", "Status", "Discovery Status", "Selected Capabilities"):
        assert properties[name].findtext("readonly") == "true"
    action = xml.find("./config/actions/action")
    assert action.findtext("name") == "Refresh Entities"
    assert action.findtext("command") == "RefreshEntities"
    selector = xml.find("./config/actions/action[command='SelectDevice']/params/param")
    assert selector.findtext("type") == "CUSTOM_SELECT:BrowseHADevices"
    assert selector.find("search") is not None
    assert {f.get("name") for f in selector.findall("./search/filters/filter")} == {"all", "switch", "group", "gesture"}
    commands = {entry.findtext("name"): entry for entry in xml.findall("./config/commands/command")}
    assert set(commands) == {"Turn On", "Turn Off", "Toggle", "Set LED Current Color", "Set All LED Colors", "Set LED Brightness", "Set LED Behavior"}
    assert "Button Action" not in commands
    assert [(param.findtext("name"), param.findtext("type"))
            for param in commands["Set LED Behavior"].findall("./params/param")] == [
                ("Button", "DYNAMIC_LIST"), ("Behavior", "DYNAMIC_LIST")]
    assert not {"Set Level", "Ramp To Level", "Light Action"} & set(commands)


def test_conditionals_define_only_stable_on_off_for_composer_loops():
    xml = ET.parse(ROOT / "driver.xml").getroot()
    conditions = xml.findall("./conditionals/conditional")
    assert [(c.findtext("id"), c.findtext("name"), c.findtext("type")) for c in conditions] == [
        ("0", "IS_ON", "SIMPLE"), ("1", "IS_OFF", "SIMPLE")]
    assert [c.findtext("sort_order") for c in conditions] == ["0", "1"]
    assert all("NAME" in c.findtext("description") for c in conditions)
    assert all(c.findtext("name") != "LIGHT_LEVEL" for c in conditions)
    assert "module/load_conditions.lua" in PACKAGE_FILES
