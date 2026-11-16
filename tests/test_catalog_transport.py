"""Actual HA sensor -> actual Coordinator packet limits -> names-only client."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest

from tools.build_switch import ROOT

EXPORT = r'''
import asyncio, json, logging, pathlib, shutil, sys
from homeassistant import config_entries, loader
from homeassistant.bootstrap import async_load_base_functionality
from homeassistant.components.light import ColorMode, LightEntityFeature
from homeassistant.core import HomeAssistant
from homeassistant.helpers import area_registry as ar, device_registry as dr, entity_registry as er
from homeassistant.const import EntityCategory
from homeassistant.helpers.json import json_bytes
from homeassistant.helpers.entity_component import EntityComponent
from homeassistant.helpers.template import Template
from custom_components.ha_gesture_bridge.sensor import GestureCatalogSensor

async def main():
 folder, count = pathlib.Path(sys.argv[1]), int(sys.argv[2])
 projection = json.loads((folder/'projection-request.json').read_text())
 config = folder / 'ha'
 shutil.copytree(pathlib.Path.cwd()/'custom_components/ha_gesture_bridge', config/'custom_components/ha_gesture_bridge',
                 ignore=shutil.ignore_patterns('__pycache__'))
 hass=HomeAssistant(str(config)); hass.config_entries=config_entries.ConfigEntries(hass,{}); loader.async_setup(hass)
 assert await async_load_base_functionality(hass)
 try:
  registry=er.async_get(hass); area=ar.async_get(hass).async_create('Fixture Transport Area')
  for index in range(count):
   item=registry.async_get_or_create('switch','fixture',str(index),suggested_object_id=f'catalog_transport_fixture_load_{index:04d}',
     original_name=f'Fixture Room {index:04d} Original Paddle Switch for Transport Regression Fixture')
   registry.async_update_entity(item.entity_id,area_id=area.id)
   hass.states.async_set(item.entity_id,'off',{'raw_log':'x'*65536} if index==0 else {})
  sensor=GestureCatalogSensor()
  component=EntityComponent(logging.getLogger(__name__),'sensor',hass)
  await component.async_add_entities([sensor]); await hass.async_block_till_done()
  state=hass.states.get(sensor.entity_id); attrs=dict(state.attributes)
  hass.states.async_set('sensor.unrelated_large_payload','idle',{'raw_log':'x'*262144})
  broad=json.loads(Template(projection['template'],hass).async_render(
    {'entity_ids':[],'domains':['switch'],'attribute_keys':[]},parse_result=False))
  assert len(broad)==count and all(row['entity_id'].startswith('switch.') for row in broad)
  assert all('raw_log' not in row['attributes'] for row in broad)
  # Exercise native Python HA types before JSON transport. JSON-only fixtures
  # hide this failure because their sets have already become lists.
  hass.states.async_set('light.native_group','on',{
    'friendly_name':'Group "quoted" – native',
    'entity_id':{'light.member_a','light.member_b'},
    'supported_color_modes':{ColorMode.BRIGHTNESS},
    'supported_features':LightEntityFeature.TRANSITION,
    'metadata':{'nested':{'a','b'},'values':[False,None,{},[],(1,'x')]},
    'raw_log':'x'*65536})
  native=json.loads(Template(projection['template'],hass).async_render(
    {'entity_ids':['light.native_group'],'domains':['light'],
     'attribute_keys':['entity_id','supported_color_modes','supported_features','metadata']},parse_result=False))
  assert len(native)==1 and native[0]['entity_id']=='light.native_group'
  values=native[0]['attributes']
  assert set(values['entity_id'])=={'light.member_a','light.member_b'}
  assert values['supported_color_modes']==['brightness']
  assert values['supported_features']==int(LightEntityFeature.TRANSITION)
  assert values['friendly_name']=='Group "quoted" – native' and 'raw_log' not in values
  assert set(values['metadata']['nested'])=={'a','b'}
  assert values['metadata']['values']==[False,None,{},[],[1,'x']]
  last=attrs['catalog_entities'][-1]
  manifest=['catalog_contract_version','catalog_names_version','catalog_names_revision',
    'catalog_names_total','catalog_names_pages','catalog_names_error']
  projected=[]
  for keys in [manifest] + [manifest+[f'catalog_names_page_{page:03d}'] for page in range(1,attrs['catalog_names_pages']+1)]:
   rendered=Template(projection['template'],hass).async_render(
     {'entity_ids':[sensor.entity_id],'attribute_keys':keys},parse_result=False)
   states=json.loads(rendered)
   assert 'catalog_entities' not in states[0]['attributes']
   projected.append({'keys':keys,'states':states})
  output={'catalog_entity_id':sensor.entity_id,'catalog_rows':count,'last_entity_id':last['entity_id'],
    'last_name':last['friendly_name'],'states':[{'entity_id':state.entity_id,'state':state.state,'attributes':attrs}]}
  output['projected']=projected
  # Device selectors use real device/config-entry/category metadata, not names.
  entries={}
  for integration in ('fixture_native','control4'):
   entry=config_entries.ConfigEntry(version=1,minor_version=1,domain=integration,
     title=integration,data={},options={},source='user',unique_id=None,
     discovery_keys={},subentries_data=[])
   # Register fixture ownership without loading network integrations.
   hass.config_entries._entries[entry.entry_id]=entry; entries[integration]=entry
  devices=dr.async_get(hass)
  def device(key,integration='fixture_native'):
   return devices.async_get_or_create(config_entry_id=entries[integration].entry_id,
     identifiers={(integration,key)},name=key)
  paddle,other,native,c4=device('Paddle'),device('Outlet'),device('Dimmer'),device('C4','control4')
  def entity(domain,key,attrs,owner='fixture_native',physical=None,category=None,platform=None):
   item=registry.async_get_or_create(domain,platform or owner,key,
     config_entry=entries[owner],suggested_object_id='profile_'+key,
     device_id=physical.id if physical else None,entity_category=category)
   hass.states.async_set(item.entity_id,'on' if domain!='event' else 'unknown',attrs)
   return item
  load=entity('switch','paddle',{},physical=paddle)
  wrapper=entity('light','wrapper',{'supported_color_modes':{'onoff'}},physical=paddle,platform='switch_as_x')
  registry.async_update_entity_options(wrapper.entity_id,'switch_as_x',{'entity_id':load.id,'invert':False})
  outlet=entity('switch','outlet',{},physical=other)
  lamp=entity('light','lamp',{'supported_color_modes':{ColorMode.BRIGHTNESS},
      'supported_features':LightEntityFeature.TRANSITION},physical=native)
  basic=entity('light','onoff',{'supported_color_modes':['onoff']},physical=other)
  group=entity('light','group',{'supported_color_modes':['brightness'],'entity_id':{lamp.entity_id}},platform='group')
  setting=entity('switch','setting',{},physical=other,category=EntityCategory.CONFIG)
  diagnostic=entity('switch','diagnostic',{},physical=other,category=EntityCategory.DIAGNOSTIC)
  helper=entity('switch','helper',{})
  hidden=entity('switch','hidden',{},physical=other)
  registry.async_update_entity(hidden.entity_id,hidden_by=er.RegistryEntryHider.USER)
  inactive=device('Inactive')
  disabled=entity('switch','disabled',{},physical=inactive)
  devices.async_update_device(inactive.id,disabled_by=dr.DeviceEntryDisabler.USER)
  scene=entity('event','scene',{'event_types':['press']},physical=paddle)
  buttons=[{'id':'top','label':'Top','gestures':[{'id':'press_1','kind':'press','label':'Single tap','press_count':1}]}]
  gesture_attrs={'bridge_contract_version':'1.0','bridge_control_id':'profile-paddle',
      'bridge_buttons':buttons,'bridge_load':None,'bridge_source_device_id':paddle.id}
  gesture=entity('event','gesture',gesture_attrs,platform='ha_gesture_bridge')
  c4light=entity('light','c4',{'supported_color_modes':['brightness']},owner='control4',physical=c4)
  c4group=entity('light','c4_group',{'supported_color_modes':['brightness'],'entity_id':{c4light.entity_id}},owner='control4')
  c4wrapper=entity('light','c4_wrapper',{'supported_color_modes':['onoff']},physical=c4,platform='switch_as_x')
  bad_gesture=entity('event','c4_gesture',gesture_attrs|{'bridge_source_device_id':c4.id},platform='ha_gesture_bridge')
  malformed=entity('event','malformed',gesture_attrs|{'bridge_contract_version':17},platform='ha_gesture_bridge')
  controls=[load,wrapper,outlet,lamp,basic,group,setting,diagnostic,helper,hidden,disabled,scene,gesture,c4light,c4group,c4wrapper,bad_gesture,malformed]
  scope=[item.entity_id for item in controls]
  output['selector_cases']={}
  for profile,expected in [('switch',{outlet.entity_id,basic.entity_id,gesture.entity_id}),
       ('dimmer',{outlet.entity_id,lamp.entity_id,basic.entity_id,group.entity_id,gesture.entity_id})]:
   variables={'selector':profile,'domains':['switch','light','event'],'entity_ids':scope,
     'attribute_keys':['entity_id','supported_color_modes','supported_features','bridge_contract_version','bridge_control_id','bridge_buttons','bridge_load'],
     'candidates_only':True}
   candidates=json.loads(Template(projection['template'],hass).async_render(variables,parse_result=False))
   assert not {helper.entity_id,hidden.entity_id,disabled.entity_id,scene.entity_id,c4light.entity_id,c4group.entity_id,c4wrapper.entity_id,bad_gesture.entity_id,malformed.entity_id}.intersection(candidates)
   eligible=[item for item in candidates if registry.async_get(item).entity_category is None]
   if load.entity_id in eligible and wrapper.entity_id in eligible: eligible.remove(load.entity_id)
   selected=json.loads(Template(projection['template'],hass).async_render(
      variables|{'entity_ids':eligible,'candidates_only':False},parse_result=False))
   assert {item['entity_id'] for item in selected}==expected
   output['selector_cases'][profile]={'candidates':candidates,'eligible_ids':eligible,
      'registry':{item:registry.async_get(item).extended_dict for item in candidates},
      'states':selected,'expected_ids':sorted(expected),'keys':variables['attribute_keys'],'scope':scope}
  (folder/'catalog.json').write_bytes(json_bytes(output))
 finally:
  await hass.async_stop(force=True)
asyncio.run(main())
'''


@pytest.mark.parametrize("rows", [100, 1400])
@pytest.mark.parametrize("runtime", ["lua", "luajit"])
def test_actual_ha_catalog_names_cross_bounded_coordinator(rows, runtime, tmp_path):
    checkout = os.environ.get("HA_GESTURE_BRIDGE_CHECKOUT")
    coordinator = os.environ.get("C4_HA_COORDINATOR_CHECKOUT")
    if not checkout or not coordinator:
        pytest.skip("Set HA_GESTURE_BRIDGE_CHECKOUT and C4_HA_COORDINATOR_CHECKOUT for actual catalog transport")
    bridge = Path(checkout).resolve()
    python = Path(os.environ.get("HA_GESTURE_BRIDGE_PYTHON", bridge / ".venv/bin/python"))
    executable = shutil.which(runtime)
    if executable is None:
        pytest.skip(f"Install {runtime} for the bounded catalog transport")
    # Execute the actual Coordinator request builder. Python renders its fixed
    # template in real HA; the Lua boundary consumes the resulting publications.
    program = '''package.path=arg[1]..'/?.lua;'..package.path
local J=require('module.json'):new({strictTypes=true})
local P=require('module.state_projection')
io.write(J:encode(P.request({entity_ids=J:newArray({'sensor.placeholder'}),attribute_keys=J:newArray()})))
'''
    request = subprocess.run([executable, "-", str(Path(coordinator).resolve())], input=program,
        capture_output=True, text=True, timeout=15)
    assert request.returncode == 0, request.stderr
    (tmp_path / "projection-request.json").write_text(request.stdout)
    result = subprocess.run([str(python), "-c", EXPORT, str(tmp_path), str(rows)], cwd=bridge,
        capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run([executable, "tests/controller/test_catalog_transport.lua",
        str(Path(coordinator).resolve()), str(tmp_path / "catalog.json")], cwd=ROOT,
        capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "actual HA rows" in result.stdout
    assert "projected HA bytes" in result.stdout
    result = subprocess.run([executable, "tests/controller/test_selector_transport.lua",
        str(Path(coordinator).resolve()), str(tmp_path / "catalog.json")], cwd=ROOT,
        capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Actual HA selector transport passed" in result.stdout
