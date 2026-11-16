-- Pure RFC3339 revisions shared by load state and gesture consumers.
local M={}
-- Compare RFC3339 revisions across offsets; late GET replies cannot replace
-- newer events or grant capabilities from a previous selection.
function M.parse(value)
    if type(value)~='string' then return nil end
    local y,m,d,h,n,s,tail=value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$')
    if not y then return nil end
    y,m,d,h,n,s=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(n),tonumber(s)
    local leap=y%4==0 and (y%100~=0 or y%400==0)
    local days={31,leap and 29 or 28,31,30,31,30,31,31,30,31,30,31}
    if y<1 or m<1 or m>12 or d<1 or d>days[m] or h>23 or n>59 or s>59 then return nil end
    local fraction=''
    if tail:sub(1,1)=='.' then
        fraction,tail=tail:match('^%.(%d+)(.*)$')
        if not fraction then return nil end
    end
    local offset=0
    if tail~='Z' then
        local sign,oh,om=tail:match('^([+-])(%d%d):(%d%d)$')
        oh,om=tonumber(oh),tonumber(om)
        if not sign or oh>23 or om>59 then return nil end
        offset=(oh*60+om)*(sign=='+' and 1 or -1)
    end
    local ay=y-(m<=2 and 1 or 0)
    local era=math.floor(ay/400); local yoe=ay-era*400
    local shifted=m+(m>2 and -3 or 9)
    local doy=math.floor((153*shifted+2)/5)+d-1
    local ordinal=era*146097+yoe*365+math.floor(yoe/4)-math.floor(yoe/100)+doy-719468
    return {seconds=ordinal*86400+h*3600+n*60+s-offset*60,
        fraction=(fraction..'000000000'):sub(1,9)}
end
function M.compare(a,b)
    if a.seconds~=b.seconds then return a.seconds<b.seconds and -1 or 1 end
    if a.fraction~=b.fraction then return a.fraction<b.fraction and -1 or 1 end
    return 0
end

return M
