local P=require('module.gesture_presentation')
local n=0
local function eq(a,b) n=n+1; assert(a==b,'expected '..tostring(b)..', got '..tostring(a)) end
local function gesture(kind,id,label,count) return {kind=kind,id=id,label=label,press_count=count} end
local function button(id,label)
    return {id=id,label=label,gestures={gesture('custom','scene','Movie Scene'),gesture('press','press_3','3 Press',3),
        gesture('hold_start','hold','Hold Start'),gesture('release','release','Release'),gesture('press','press_1','1 Press',1),
        gesture('hold_repeat','repeat_hold','Hold Repeat'),gesture('press','press_5','5 Press',5),gesture('press','press_2','2 Press',2),gesture('press','press_4','4 Press',4)}}
end
local top,bottom=button('top','Top'),button('bottom','Bottom')
local events=P.build({bottom,top})
local expected={'Top Button Released','Bottom Button Released','Top Single Tap','Top Double Tap','Top Triple Tap','Top 4 Taps','Top 5 Taps',
    'Bottom Single Tap','Bottom Double Tap','Bottom Triple Tap','Bottom 4 Taps','Bottom 5 Taps',
    'Top Hold Start','Bottom Hold Start','Top Hold Repeat','Bottom Hold Repeat','Top Movie Scene','Bottom Movie Scene'}
eq(#events,#expected)
for i,event in ipairs(events) do
    eq(event.name,expected[i]); eq(event.description,'When NAME '..expected[i]); eq(event.order,i)
    eq(event.key,event.button_id..'/'..event.gesture_id)
    n=n+1; assert(not event.name:find('Pushed') and not event.name:find('Level Changes'))
end
-- Sorting and display names never rewrite source definitions or key identity.
eq(bottom.gestures[1].id,'scene'); eq(bottom.gestures[5].label,'1 Press')
local renamed=P.describe({id='top',label='Upper Paddle'},gesture('press','press_2','Deux',2))
eq(renamed.name,'Upper Paddle Double Tap'); eq(renamed.key,'top/press_2')
local other=P.describe({id='key_7',label='Patio'},gesture('release','released','Released'))
eq(other.name,'Patio Button Released'); eq(other.key,'key_7/released')
local misleading=P.describe({id='key_7',label='Patio'},gesture('custom','press_1','Recall Scene'))
eq(misleading.name,'Patio Recall Scene'); eq(misleading.kind,'custom')
local hold=P.describe(top,gesture('hold_start','hold_start','Holding'))
eq(hold.name,'Top Holding'); eq(hold.key,'top/hold_start')
local repeat_hold=P.describe(top,gesture('hold_repeat','hold_repeat','Dimming Repeat'))
eq(repeat_hold.name,'Top Dimming Repeat')
local many=P.describe(top,gesture('press','press_12','12 Press',12)); eq(many.name,'Top 12 Taps'); eq(many.press_count,12)
local keys=P.build({button('z_other','Other Label'),bottom,button('a_other','Other Label'),top})
eq(keys[1].button_id,'top'); eq(keys[2].button_id,'bottom'); eq(keys[3].button_id,'a_other'); eq(keys[4].button_id,'z_other')
local supported={}
for _,id in ipairs({'bottom','top'}) do
    supported[#supported+1]={id=id,label=id=='top' and 'Top' or 'Bottom',gestures={
        gesture('press','press_3','3 Press',3),gesture('press','press_2','2 Press',2),gesture('press','press_1','1 Press',1),
        gesture('release','release','Release'),gesture('custom','button_pushed','Button Pushed')}}
end
local native_options=P.build(supported)
local native_expected={'Top Button Pushed','Top Button Released','Bottom Button Pushed','Bottom Button Released',
    'Top Single Tap','Top Double Tap','Top Triple Tap','Bottom Single Tap','Bottom Double Tap','Bottom Triple Tap'}
eq(#native_options,#native_expected)
for index,event in ipairs(native_options) do eq(event.name,native_expected[index]); eq(event.order,index) end
eq(native_options[1].key,'top/button_pushed'); eq(native_options[1].kind,'custom')
eq(native_options[3].key,'bottom/button_pushed'); eq(native_options[3].kind,'custom')
eq(supported[1].gestures[5].label,'Button Pushed'); eq(supported[1].gestures[5].kind,'custom')
local no_inference=P.build({{id='top',label='Top',gestures={
    gesture('hold_start','hold','Hold Start'),gesture('custom','button_pushed','Other Action')}}})
eq(#no_inference,2); eq(no_inference[1].name,'Top Hold Start'); eq(no_inference[2].name,'Top Other Action')
print('Gesture presentation: '..n..' assertions passed')
