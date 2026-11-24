-- update16: 지운 기록 보관함(fw_trash) + 대량 삭제 차단
create table if not exists public.fw_trash(n bigserial primary key, col text, id text, data jsonb, who text, role text, at timestamptz not null default now());
alter table public.fw_trash enable row level security;

create or replace function public.fw_push(p_token uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; v_ndel int; x jsonb; v_col text; v_id text; v_data jsonb; v_sid text; v_old public.fw_rec; n int:=0; v_kids jsonb; v_pname text;
begin
  s:=fw_who(p_token);
  -- 안전장치: 한 번에 10개 넘게 지우려는 요청은 지우기만 무시 (옛날 버전 앱이 새 기록을 지우는 사고 방지)
  select count(*) into v_ndel from jsonb_array_elements(p_rows) e where jsonb_typeof(e->'data') is distinct from 'object';
  if s.role='parent' then v_kids:=fw_pkids(s.uid);
    select string_agg(data->>'name','·' order by data->>'name')||' 학부모님' into v_pname from fw_rec
    where col='S' and v_kids ? id and coalesce(data->>'grad','') in ('','false','0'); end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_col:=x->>'col'; v_id:=x->>'id'; v_data:=case when jsonb_typeof(x->'data')='object' then x->'data' end;
    select * into v_old from fw_rec where col=v_col and id=v_id;
    v_sid:=case when v_col in ('S','P','T','N','W') then v_id when v_data is not null then v_data->>'sid' else v_old.sid end;
    if s.role='parent' then
      continue when v_col<>'PM';
      continue when v_old.col is not null and v_old.data is not null and coalesce(v_old.data->>'by','')<>s.uid;
      continue when v_data is null and v_old.col is null;
      if v_data is not null then
        continue when not (v_kids ? coalesce(v_data->>'sid',''));
        v_data:=v_data||jsonb_build_object('by',s.uid,'role','parent','seen',0,'name',coalesce(v_pname,'학부모님'));
        v_sid:=v_data->>'sid';
      end if;
    end if;
    if s.role='student' then
      continue when v_data is null;
      continue when not ((v_col in ('tasks','R','Q','PR','V','A','K','X','SD','RS') and v_sid=s.uid and (v_old.sid is null or v_old.sid=s.uid))
                         or (v_col in ('P','W') and v_id=s.uid));
    end if;
    if v_data is null and v_ndel>10 then continue; end if;
    if v_col='RS' and v_id<>s.uid then continue; end if;
    if v_col='RS' and v_data is not null then v_data:=v_data||jsonb_build_object('sid',s.uid); v_sid:=s.uid; end if;
    if s.role='teacher' and v_col='T' and v_id<>s.uid then continue; end if;
    if s.role='teacher' and v_col='T' and v_data is not null then v_data:=v_data||jsonb_build_object('role','teacher'); end if;
    if v_col='T' and v_data is not null and not v_data ? 'pw' and v_old.data ? 'pw' then
      v_data:=v_data||jsonb_build_object('pw',v_old.data->'pw'); end if;
    if v_data is null and v_old.data is not null then
      insert into fw_trash(col,id,data,who,role) values(v_col,v_id,v_old.data,s.uid,s.role); end if;
    insert into fw_rec(col,id,data,sid,updated_at) values(v_col,v_id,v_data,v_sid,clock_timestamp())
    on conflict(col,id) do update set data=excluded.data, sid=excluded.sid, updated_at=clock_timestamp();
    n:=n+1;
  end loop;
  return jsonb_build_object('saved',n);
end $$;
grant execute on function public.fw_push(uuid, jsonb) to anon, authenticated;

select 'OK update16' as result;
