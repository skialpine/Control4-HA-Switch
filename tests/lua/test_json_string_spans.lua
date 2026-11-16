-- String decoding must stay compatible while copying unescaped spans once.
local paths={'module/json.lua'}
local coordinator=os.getenv('C4_HA_COORDINATOR_CHECKOUT')
if coordinator then paths[#paths+1]=coordinator..'/module/json.lua' end
local assertions=0
local function eq(actual,expected,message)
    assertions=assertions+1
    assert(actual==expected,message or ('string regression '..assertions))
end
local euro=string.char(0xE2,0x82,0xAC)
local smile=string.char(0xF0,0x9F,0x98,0x80)
for _,path in ipairs(paths) do
    local JSON=assert(loadfile(path))()
    local null={}
    local codec=JSON:new({strictTypes=true,null=null})
    local cases={
        {[=[""]=],''},
        {[=["ordinary text with spaces"]=],'ordinary text with spaces'},
        {[=["\b\f\n\r\t\"\\\/"]=],'\b\f\n\r\t"\\/'},
        {[=["before\u0041\u00E9\u20ac\uD83D\uDE00after"]=],
            'beforeA'..string.char(0xC3,0xA9)..euro..smile..'after'},
        -- Preserve this codec's existing permissive escape/surrogate behavior.
        {[=["\z\u12xz"]=],'zu12xz'},
        {[=["\uD800x"]=],'?x'},
        {[=["\uDC00"]=],'?'},
        {'"prefix'..string.char(0,1,31)..'"','prefix'..string.char(0,1,31)},
    }
    for _,case in ipairs(cases) do eq(codec:decode(case[1]),case[2],path..' decoded string changed') end
    local object=codec:decode([=[{"na\u006de":"first","quote\"key":"second","after":false,"nil":null}]=])
    eq(object.name,'first'); eq(object['quote"key'],'second')
    eq(object.after,false); eq(object['nil'],null)
    local plain=string.rep('registry-value-',65536)
    eq(codec:decode('"'..plain..'"'),plain,'Long unescaped registry/state attribute')
    local encoded=string.rep([=[prefix\n\u20AC\\suffix]=],4096)
    local decoded=string.rep('prefix\n'..euro..'\\suffix',4096)
    local array=codec:decode('["'..encoded..'","tail",""]')
    eq(array[1],decoded); eq(array[2],'tail'); eq(array[3],'')
    eq(codec:decode(codec:encode({value=decoded})).value,decoded)

    local original_print=print
    print=function() end
    codec.onDecodeError=function() error('invalid string',0) end
    for _,raw in ipairs({'"unterminated','"terminal\\','{"x":"missing}','["escaped\\"]'}) do
        eq(codec:decode(raw),nil,'Malformed string must remain a decode failure')
    end
    print=original_print
end
print('JSON string spans: '..#paths..' codecs, '..assertions..' assertions passed')
