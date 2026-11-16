"""Fresh native Dimmer packaging must not mutate the legacy Switch identity."""

from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

from tools.build_light import ROOT, build, package_sources


def test_native_dimmer_package_is_distinct_deterministic_and_runtime_only(tmp_path):
    first, second = tmp_path / "HA.Light.c4z", tmp_path / "second.c4z"
    assert build(first) == build(second)
    assert first.read_bytes() == second.read_bytes()
    with zipfile.ZipFile(first) as package:
        sources = package_sources()
        assert set(package.namelist()) == set(sources)
        for name, expected in sources.items():
            assert package.read(name) == expected
        assert "commands.lua" not in sources
        assert not any(name.startswith(("tests/", "tools/", "custom_components/", "Control4-HA-Base/")) for name in sources)
        xml = ET.fromstring(package.read("driver.xml"))
        assert xml.find("./config/script").get("file") == "light/driver.lua"
        assert xml.findtext("name") == xml.findtext("model") == "HA Light"
        assert xml.findtext("version") == "1"
        assert xml.find("replaces") is None
        assert xml.findtext("combo", "false").lower() == "false"
        proxies = xml.findall("./proxies/proxy") + xml.findall("./proxy")
        assert len(proxies) == 1
        assert proxies[0].text.strip().lower() == "light_v2"
        assert proxies[0].get("proxybindingid") == "5001"


def test_switch_and_dimmer_have_separate_entrypoints_and_proxy_topologies():
    switch = ET.parse(ROOT / "driver.xml").getroot()
    dimmer = ET.parse(ROOT / "light/driver.xml").getroot()
    assert switch.findtext("proxy") == "other"
    assert switch.findtext("combo") == "true"
    assert switch.find("proxies") is None
    assert switch.findtext("name") != dimmer.findtext("name")
    assert switch.find("./config/script").get("file") != dimmer.find("./config/script").get("file")
    connections = {c.findtext("id"): c for c in dimmer.findall("./connections/connection")}
    assert {"5001", "999", "200", "201", "202"} <= connections.keys()
    assert connections["999"].findtext("./classes/class/classname") == "HA_DEVICE"
    assert connections["999"].findtext("consumer").lower() == "true"
    properties = {p.findtext("name"): p for p in dimmer.findall("./config/properties/property")}
    assert properties["Entity ID"].findtext("type") == "STRING"
    assert properties["Debug Mode"].findtext("type") == "LIST"
    assert properties["Debug Mode"].findtext("default") == "Off"
    for name, default in (("LED On Color", "255,255,255"), ("LED Off Color", "0,0,0")):
        assert properties[name].findtext("type") == "COLOR_SELECTOR"
        assert properties[name].findtext("default") == default
        assert properties[name].findtext("readonly") == "false"
    assert [item.text for item in properties["Debug Mode"].findall("./items/item")] == ["Off", "On"]
    assert dimmer.findtext("./capabilities/has_leds", "false").lower() == "true"
    assert dimmer.findtext("./capabilities/supports_color", "false").lower() == "false"
    assert dimmer.findtext("./capabilities/supports_brightness_stop", "false").lower() == "false"


def test_dimmer_controller_links_consume_control_without_replacing_existing_links():
    dimmer = ET.parse(ROOT / "light/driver.xml").getroot()
    entries = dimmer.findall("./connections/connection")
    connections = {entry.findtext("id"): entry for entry in entries}
    assert len(connections) == len(entries)
    assert set(connections) == {"999", "200", "201", "202", "203", "204", "205", "5001"}
    expected = {
        "200": ("Top Button Link", "false"),
        "201": ("Bottom Button Link", "false"),
        "202": ("Toggle Button Link", "false"),
        "203": ("Top Controller Link", "true"),
        "204": ("Bottom Controller Link", "true"),
        "205": ("Toggle Controller Link", "true"),
    }
    for identifier, (name, consumer) in expected.items():
        connection = connections[identifier]
        assert connection.findtext("connectionname") == name
        assert connection.findtext("consumer").lower() == consumer
        assert connection.findtext("facing") == "6"
        assert connection.findtext("type") == "1"
        assert connection.findtext("./classes/class/classname") == "BUTTON_LINK"
        assert connection.findtext("audiosource").lower() == "false"
        assert connection.findtext("videosource").lower() == "false"
        assert connection.findtext("linelevel").lower() == "true"
    assert dimmer.findtext("version") == "1"
