-- 상담 일지(N)는 학생에게 안 보이게, 단어장(W)은 학생이 저장할 수 있게
create or replace function public.fw_pull(p_token uuid, p_since timestamptz) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; v_now timestamptz:=clock_timestamp(); v_rows jsonb;
begin
  s:=fw_who(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('col',r.col,'id',r.id,'data',
    case
      when r.data is null then null
      when r.col='T' and not (s.role='owner' or r.id=s.uid) then r.data-'pw'
      when r.col='E' and s.role='student' then (r.data-'res')||jsonb_build_object('res',
           case when r.data->'res' ? s.uid then jsonb_build_object(s.uid,r.data->'res'->s.uid) else '{}'::jsonb end)
      else r.data end)),'[]'::jsonb)
  into v_rows
  from fw_rec r
  where (p_since is null and r.data is not null or r.updated_at>p_since)
    and (s.role<>'student' or (r.col<>'N' and (r.col in ('T','C','E','meta') or r.sid=s.uid)));
  return jsonb_build_object('now',v_now,'rows',v_rows);
end $$;

create or replace function public.fw_push(p_token uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; x jsonb; v_col text; v_id text; v_data jsonb; v_sid text; v_old public.fw_rec; n int:=0;
begin
  s:=fw_who(p_token);
  for x in select * from jsonb_array_elements(p_rows) loop
    v_col:=x->>'col'; v_id:=x->>'id'; v_data:=case when jsonb_typeof(x->'data')='object' then x->'data' end;
    select * into v_old from fw_rec where col=v_col and id=v_id;
    v_sid:=case when v_col in ('S','P','T','N','W') then v_id when v_data is not null then v_data->>'sid' else v_old.sid end;
    if s.role='student' then
      continue when v_data is null;
      continue when not ((v_col in ('tasks','R','Q') and v_sid=s.uid and (v_old.sid is null or v_old.sid=s.uid))
                         or (v_col in ('P','W') and v_id=s.uid));
    end if;
    if v_col='T' and v_data is not null and not v_data ? 'pw' and v_old.data ? 'pw' then
      v_data:=v_data||jsonb_build_object('pw',v_old.data->'pw'); end if;
    insert into fw_rec(col,id,data,sid,updated_at) values(v_col,v_id,v_data,v_sid,clock_timestamp())
    on conflict(col,id) do update set data=excluded.data, sid=excluded.sid, updated_at=clock_timestamp();
    n:=n+1;
  end loop;
  return jsonb_build_object('saved',n);
end $$;

-- 테스트 학생 계정 (이름: 테스트학생 / 코드: 20260000)
insert into fw_rec(col,id,data,sid)
select 'S','s_test',jsonb_build_object('id','s_test','name','테스트학생','school','테스트고','grade','고1','phone','','parent','',
  'code','20260000','tid',(select id from fw_rec where col='T' and data->>'role'='owner' limit 1),'days','[1,3,5]'::jsonb,'reg',to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD')),'s_test'
on conflict(col,id) do nothing;

select col, id, data->>'name' as name, data->>'code' as code, data->>'cid' as cid, data->>'tid' as tid from fw_rec where col in ('S','T','C') and data is not null order by col;
