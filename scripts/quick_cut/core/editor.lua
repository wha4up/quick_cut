local E={}
local deps={}
function E.init(d)
    if d then for k,v in pairs(d) do deps[k]=v end end
end
local function L(...) if deps.L then return deps.L(...) end end
local function copy(v) if type(v)~="table" then return v end; local o={}; for k,x in pairs(v) do o[k]=copy(x) end; return o end
function E.clone_segment(s) return {id=s.id,label=s.label,enabled=s.enabled~=false,start_time=s.start_time,end_time=s.end_time,crop=copy(s.crop)} end
function E.clone_segments(list) local o={}; for i,s in ipairs(list or {}) do o[i]=E.clone_segment(s) end; return o end
function E.snapshot(s) return {start_time=s.start_time,end_time=s.end_time,segments=E.clone_segments(s.segments),next_id=s.next_id,active_handle=s.active_handle,editing_id=s.editing_id,manual_order=s.manual_order,selected_segment_id=s.selected_segment_id,segment_scroll=s.segment_scroll} end
function E.normalize_segment(s, e, duration, minimum)
    duration = tonumber(duration) or 0
    if s == nil and e == nil then return nil, L("hint.no_times") end
    s, e = s or 0, e or duration
    if s > e then s, e = e, s end
    s, e = math.max(0, math.min(duration, s)), math.max(0, math.min(duration, e))
    local min = tonumber(minimum) or 0.05
    if e - s < min then
        return nil, L("hint.min_segment_seconds", min)
    end
    return {start_time=s, end_time=e}, nil
end
function E.sort_segments(list)
    table.sort(list, function(a, b)
        if a.start_time == b.start_time then return a.end_time < b.end_time end
        return a.start_time < b.start_time
    end)
end
function E.find_segment_index(list,id) if id==nil then return end; for i,s in ipairs(list or {}) do if s.id==id then return i,s end end end
function E.apply_snapshot(s,x,maxv) if not x then return false end; s.start_time,s.end_time=x.start_time,x.end_time; s.segments,s.next_id=E.clone_segments(x.segments),x.next_id or 1; s.active_handle=x.active_handle or "start"; s.editing_id=x.editing_id; s.manual_order=x.manual_order==true; s.selected_segment_id=x.selected_segment_id; s.segment_scroll=math.min(x.segment_scroll or 0,math.max(0,#s.segments-(tonumber(maxv) or 7))); if s.selected_segment_id and not E.find_segment_index(s.segments,s.selected_segment_id) then s.selected_segment_id=nil end; if s.editing_id and not E.find_segment_index(s.segments,s.editing_id) then s.editing_id=nil end
    -- 勾选集合与片段列表是两份状态：撤销会把 next_id 一起回退，残留的勾选 id 会被后来
    -- 新建的片段"继承"，一次删除就能删掉用户从没勾过的片段。这里同步修剪掉失效 id。
    if type(s.checked) == "table" then
        local keep = {}
        for _, id in ipairs(s.checked) do
            if E.find_segment_index(s.segments, id) then keep[#keep+1] = id end
        end
        s.checked = keep
    end
    return true end
function E.new_history(limit) return {undo={},redo={},limit=tonumber(limit) or 50,suspended=false} end
function E.history_push(h,x) if h.suspended then return false end; table.insert(h.undo,x); if #h.undo>h.limit then table.remove(h.undo,1) end; h.redo={}; return true end
function E.history_undo(h,current) local x=table.remove(h.undo); if not x then return end; table.insert(h.redo,current); return x end
function E.history_redo(h,current) local x=table.remove(h.redo); if not x then return end; table.insert(h.undo,current); return x end
function E.history_clear(h) h.undo,h.redo={},{} end
local function width(b) return math.max(1,(b.x2 or 0)-(b.x1 or 0)) end
function E.time_to_x(t,d,b) if t==nil or not d or d<=0 then return end; return (b.x1 or 0)+math.max(0,math.min(d,t))/d*width(b) end
function E.x_to_time(x,d,b,snap) local x1,x2=b.x1 or 0,b.x2 or 0; snap=tonumber(snap) or 0; if x<=x1+snap then return 0 end; if x>=x2-snap then return d end; return math.max(0,math.min(d,(x-x1)/width(b)*d)) end
function E.find_handle(x,d,b,draft,radius,active) local r=tonumber(radius) or 10; local xs={}; if draft.start_time~=nil then xs[#xs+1]={handle="start",x=E.time_to_x(draft.start_time,d,b)} end; if draft.end_time~=nil then xs[#xs+1]={handle="end",x=E.time_to_x(draft.end_time,d,b)} end; if active then for _,i in ipairs(xs) do if i.handle==active and math.abs(x-i.x)<=r then return active end end end local n,dist=nil,math.huge; for _,i in ipairs(xs) do local q=math.abs(x-i.x); if q<=r and q<dist then n,dist=i,q end end; return n and n.handle or nil end
function E.find_segments_at_time(list,t) local o={}; for i,s in ipairs(list or {}) do if t>=s.start_time and t<=s.end_time then o[#o+1]={index=i,segment=s} end end; return o end
function E.cycle_candidate(c,id) if #c==0 then return end; for i,x in ipairs(c) do if x.segment.id==id then return c[i%#c+1] end end; return c[#c] end
function E.can_split(s,t,min) if not s or t==nil then return false,L("hint.no_split_target") end; local g=tonumber(min) or .05; if t<=s.start_time+g or t>=s.end_time-g then return false,L("hint.split_too_close") end; return true end
function E.split_segment(s,i,t) local a=s.segments[i]; if not a then return nil,L("hint.no_split_target") end; local l,r=E.clone_segment(a),E.clone_segment(a); l.end_time=t; r.start_time=t; r.id=s.next_id; s.next_id=s.next_id+1; l.label=nil; r.label=nil; s.segments[i]=l; table.insert(s.segments,i+1,r); s.selected_segment_id=r.id; s.editing_id=nil; return r,l end
function E.clamp_handle(handle,value,start_time,end_time,duration,minimum) local v=math.max(0,math.min(duration,value)); local gap=tonumber(minimum) or .05; if handle=="start" and end_time~=nil then v=math.min(v,math.max(0,end_time-gap)) elseif handle=="end" and start_time~=nil then v=math.max(v,math.min(duration,start_time+gap)) end; return v end
function E.interval_at(list, t, duration)
    local L = 0
    local R = (duration and duration > 0) and duration or nil
    for _, s in ipairs(list or {}) do
        if s.start_time ~= nil then
            if s.start_time <= t and s.start_time > L then L = s.start_time end
            if s.start_time >= t and (R == nil or s.start_time < R) then R = s.start_time end
        end
        if s.end_time ~= nil then
            if s.end_time <= t and s.end_time > L then L = s.end_time end
            if s.end_time >= t and (R == nil or s.end_time < R) then R = s.end_time end
        end
    end
    return L, R
end
function E.insert_segment_at_time(s, start_time, end_time)
    local x = {id = s.next_id, enabled = true, start_time = start_time, end_time = end_time}
    s.next_id = s.next_id + 1
    local at = #s.segments + 1
    for i, seg in ipairs(s.segments) do
        if seg.start_time and seg.start_time > start_time then at = i; break end
    end
    table.insert(s.segments, at, x)
    s.selected_segment_id = x.id
    return x, at
end
return E
