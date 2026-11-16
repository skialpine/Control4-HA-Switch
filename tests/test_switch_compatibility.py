"""Guard the installed-instance contract against the original v106 XML."""

from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def normalized(element):
    return (element.tag, sorted(element.attrib.items()), (element.text or "").strip(),
            [normalized(child) for child in element])


def test_existing_proxy_and_connections_are_unchanged():
    old = ET.parse(ROOT / "tests/fixtures/legacy-switch.xml").getroot()
    new = ET.parse(ROOT / "driver.xml").getroot()
    assert int(new.findtext("version")) == int(old.findtext("version")) + 1
    for tag in ("name", "model", "manufacturer", "proxy", "combo"):
        assert normalized(new.find(tag)) == normalized(old.find(tag)), tag
    old_connections = {c.findtext("id"): normalized(c) for c in old.findall("./connections/connection")}
    new_connections = {c.findtext("id"): normalized(c) for c in new.findall("./connections/connection")}
    assert new_connections == old_connections
    assert new.find("proxies") is None
    assert len(new.findall("proxy")) == len(old.findall("proxy"))


def test_existing_defaults_and_commands_survive_upgrade():
    old = ET.parse(ROOT / "tests/fixtures/legacy-switch.xml").getroot()
    new = ET.parse(ROOT / "driver.xml").getroot()
    old_properties = {p.findtext("name"): p for p in old.findall("./config/properties/property")}
    new_properties = {p.findtext("name"): p for p in new.findall("./config/properties/property")}
    for name, prop in old_properties.items():
        assert normalized(new_properties[name]) == normalized(prop), name
    assert new_properties["Operation Mode"].findtext("default") == "Control HA Device"
    new_commands = {p.findtext("name"): p for p in new.findall("./config/commands/command")}
    for command in old.findall("./config/commands/command"):
        assert normalized(new_commands[command.findtext("name")]) == normalized(command)


def test_development_107_retains_switch_interfaces_except_explicitly_removed_beta_lighting():
    """Also protect the development build already installed on the controller.

    The user explicitly moved unreleased beta brightness/ramp commands into
    the new Dimmer. Original v106 interfaces remain protected separately.
    """
    old = ET.parse(ROOT / "tests/fixtures/development-switch-107.xml").getroot()
    new = ET.parse(ROOT / "driver.xml").getroot()
    assert new.findtext("version") == old.findtext("version") == "107"
    for tag in ("name", "model", "manufacturer", "proxy", "combo", "connections", "events"):
        assert normalized(new.find(tag)) == normalized(old.find(tag)), tag
    assert new.find("proxies") is None
    for section, element in (("properties", "property"), ("commands", "command"), ("actions", "action")):
        current = {entry.findtext("name"): entry for entry in new.findall(f"./config/{section}/{element}")}
        for previous in old.findall(f"./config/{section}/{element}"):
            name = previous.findtext("name")
            if section == "commands" and name in {"Set Level", "Ramp To Level", "Light Action", "Button Action"}:
                assert name not in current
                continue
            assert name in current, f"Removed {element}: {name}"
            if section == "properties" and name == "Operation Mode":
                # Installer labels changed by request; the Lua entry-point
                # regressions exercise the three supported Switch labels; retired beta modes are omitted.
                assert current[name].findtext("type") == previous.findtext("type")
                labels = {"Direct": "Control HA Device",
                          "Gesture Bridge": "Control HA Device with Button Events",
                          "Gestures Only": "Programming Events Only"}
                assert current[name].findtext("default") == labels[previous.findtext("default")]
                old_items = [item.text for item in previous.findall("./items/item")]
                new_items = [item.text for item in current[name].findall("./items/item")]
                assert new_items == [labels[item] for item in old_items if item in labels]
                continue
            if section == "actions" and name == "Select Device":
                for filter_node in list(previous.findall("./params/param/search/filters/filter")):
                    if filter_node.get("name") == "dimmer":
                        previous.find("./params/param/search/filters").remove(filter_node)
            assert normalized(current[name]) == normalized(previous), f"Changed {element}: {name}"
