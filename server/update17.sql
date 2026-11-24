-- update17: F:OCUS 주간 모의고사 — 학생이 자기 계정에서 답 입력 → 서버가 바로 채점
-- 1) 학생도 F:OCUS 회차(FX)를 받되, 정답·시험 자료는 빼고 받아요
-- 2) fw_focus_submit: 학생 답을 받아 서버에서 채점하고 결과(FR)를 저장해요 (한 회차에 한 번만)

create or replace function public.fw_pull(p_token uuid, p_since timestamptz) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; v_now timestamptz:=clock_timestamp(); v_rows jsonb; v_kids jsonb;
begin
  s:=fw_who(p_token);
  if s.role='parent' then
    v_kids:=fw_pkids(s.uid);
    select coalesce(jsonb_agg(jsonb_build_object('col',r.col,'id',r.id,'data',
      case
        when r.data is null then null
        when r.col='S' then jsonb_build_object('id',r.id,'name',r.data->'name','school',r.data->'school','grade',r.data->'grade',
                                               'tid',r.data->'tid','cid',r.data->'cid','grad',r.data->'grad')
        when r.col='T' then jsonb_build_object('id',r.id,'name',r.data->'name','role',r.data->'role')
        else r.data end)),'[]'::jsonb)
    into v_rows
    from fw_rec r
    where (p_since is null and r.data is not null or r.updated_at>p_since)
      and ((r.col='S' and v_kids ? r.id)
        or (r.col in ('tasks','L','PM') and v_kids ? r.sid)
        or (r.col='R' and v_kids ? r.sid and (r.data is null or r.data ? 'voca'))
        or (r.col='C' and r.data is not null)
        or r.col='T');
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object('col','PA','id',s.uid,'data',jsonb_build_object(
      'id',s.uid,'phone',substr(s.uid,3),'kids',v_kids,
      'name',(select string_agg(data->>'name','·' order by data->>'name') from fw_rec where col='S' and v_kids ? id and coalesce(data->>'grad','') in ('','false','0'))||' 학부모님')));
    return jsonb_build_object('now',v_now,'rows',v_rows);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('col',r.col,'id',r.id,'data',
    case
      when r.data is null then null
      when r.col='T' and not (s.role='owner' or r.id=s.uid) then r.data-'pw'
      when r.col='E' and s.role='student' then (r.data-'res')||jsonb_build_object('res',
           case when r.data->'res' ? s.uid then jsonb_build_object(s.uid,r.data->'res'->s.uid) else '{}'::jsonb end)
      when r.col='FX' and s.role='student' then r.data-'key'-'files'-'lsrc'
      else r.data end)),'[]'::jsonb)
  into v_rows
  from fw_rec r
  where (p_since is null and r.data is not null or r.updated_at>p_since)
    and (s.role<>'student' or (r.col not in ('N','L','PC','M','I','PM') and (r.col in ('T','C','E','meta','FX') or r.sid=s.uid)))
    and (r.col<>'RS' or r.sid=s.uid)
    and (r.col<>'M' or r.data is null or r.data->>'room'='all' or r.data->>'by'=s.uid or coalesce(r.data->'to','[]'::jsonb) ? s.uid);
  return jsonb_build_object('now',v_now,'rows',v_rows);
end $$;

create or replace function public.fw_focus_submit(p_token uuid, p_fx text, p_ans jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; fx jsonb; st jsonb; v_key jsonb; v_pts jsonb; v_ans jsonb:='[]'::jsonb;
  v_wrong jsonb:='[]'::jsonb; v_score int:=0; v_grd int; i int; a int; v_id text; v_row jsonb; v_avg numeric; v_n int; r record;
  v_now text:=to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI');
begin
  s:=fw_who(p_token);
  if s.role<>'student' then raise exception '학생 계정에서만 입력할 수 있어요'; end if;
  select data into fx from fw_rec where col='FX' and id=p_fx and data is not null;
  if fx is null then raise exception '회차를 찾을 수 없어요'; end if;
  if exists(select 1 from fw_rec where col='FR' and data is not null and data->>'fx'=p_fx and sid=s.uid) then
    raise exception '이미 입력했어요. 고칠 게 있으면 선생님께 말씀해 주세요'; end if;
  select data into st from fw_rec where col='S' and id=s.uid;
  v_key:=fx->'key'; v_pts:=fx->'pts';
  if jsonb_typeof(p_ans)<>'array' or jsonb_array_length(p_ans)<>jsonb_array_length(v_key) then raise exception '답 개수가 맞지 않아요'; end if;
  for i in 0..jsonb_array_length(v_key)-1 loop
    a:=case when (p_ans->>i) ~ '^[1-5]$' then (p_ans->>i)::int else 0 end;
    v_ans:=v_ans||to_jsonb(a);
    if a=(v_key->>i)::int then v_score:=v_score+coalesce((v_pts->>i)::int,2);
    else v_wrong:=v_wrong||to_jsonb(i+1); end if;
  end loop;
  v_grd:=case when v_score>=90 then 1 when v_score>=80 then 2 when v_score>=70 then 3 when v_score>=60 then 4
    when v_score>=50 then 5 when v_score>=40 then 6 when v_score>=30 then 7 when v_score>=20 then 8 else 9 end;
  v_id:='fr'||substr(md5(random()::text||clock_timestamp()::text),1,10);
  v_row:=jsonb_build_object('id',v_id,'by',s.uid,'at',v_now,'self',1,
    'fx',p_fx,'title',fx->'title','date',fx->'date','key',v_key,'pts',v_pts,
    'sid',s.uid,'name',coalesce(st->>'name',''),'phone','','ph4','','school',coalesce(st->>'school',''),'grade',coalesce(st->>'grade',''),
    'ans',v_ans,'score',v_score,'grd',v_grd,'wrong',v_wrong);
  insert into fw_rec(col,id,data,sid,updated_at) values('FR',v_id,v_row,s.uid,clock_timestamp());
  -- 회차 평균·석차를 모든 결과에 다시 적어 둬요
  select round(avg((data->>'score')::numeric),1), count(*) into v_avg, v_n from fw_rec where col='FR' and data is not null and data->>'fx'=p_fx;
  for r in select id, data from fw_rec where col='FR' and data is not null and data->>'fx'=p_fx loop
    update fw_rec set data=r.data||jsonb_build_object('st',jsonb_build_object('avg',v_avg,'n',v_n,
        'rank',1+(select count(*) from fw_rec y where y.col='FR' and y.data is not null and y.data->>'fx'=p_fx and (y.data->>'score')::int>(r.data->>'score')::int))),
      updated_at=clock_timestamp() where col='FR' and id=r.id;
  end loop;
  select data into v_row from fw_rec where col='FR' and id=v_id;
  return v_row;
end $$;
grant execute on function public.fw_pull(uuid,timestamptz), public.fw_focus_submit(uuid,text,jsonb) to anon, authenticated;

select 'OK update17' as result;
