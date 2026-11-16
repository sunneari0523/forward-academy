-- 오늘 접속 기록: 학생이 자기 접속(A)을 저장, 홈페이지 방문 수 집계
create table if not exists public.fw_hits(day date primary key, n int not null default 0);
alter table public.fw_hits enable row level security;
revoke all on public.fw_hits from anon, authenticated;

create or replace function public.fw_hit() returns void
language sql security definer set search_path=public as $$
  insert into fw_hits(day,n) values((now() at time zone 'Asia/Seoul')::date,1)
  on conflict(day) do update set n=fw_hits.n+1;
$$;

create or replace function public.fw_stats(p_token uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess;
begin
  s:=fw_who(p_token);
  if s.role='student' then raise exception 'auth'; end if;
  return jsonb_build_object('home',coalesce((select n from fw_hits where day=(now() at time zone 'Asia/Seoul')::date),0));
end $$;
grant execute on function public.fw_hit(), public.fw_stats(uuid) to anon, authenticated;

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
      continue when not ((v_col in ('tasks','R','Q','PR','V','A') and v_sid=s.uid and (v_old.sid is null or v_old.sid=s.uid))
                         or (v_col in ('P','W') and v_id=s.uid));
    end if;
    if s.role='teacher' and v_col='T' and v_id<>s.uid then continue; end if;
    if s.role='teacher' and v_col='T' and v_data is not null then v_data:=v_data||jsonb_build_object('role','teacher'); end if;
    if v_col='T' and v_data is not null and not v_data ? 'pw' and v_old.data ? 'pw' then
      v_data:=v_data||jsonb_build_object('pw',v_old.data->'pw'); end if;
    insert into fw_rec(col,id,data,sid,updated_at) values(v_col,v_id,v_data,v_sid,clock_timestamp())
    on conflict(col,id) do update set data=excluded.data, sid=excluded.sid, updated_at=clock_timestamp();
    n:=n+1;
  end loop;
  return jsonb_build_object('saved',n);
end $$;

-- 홈페이지 상담 신청: 누구나 신청 가능(로그인 없이), 선생님 화면 '상담 문의'에 저장
create or replace function public.fw_inquiry(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_id text:=gen_random_uuid()::text; v_ph text:=left(coalesce(p->>'parent',''),20);
begin
  if length(regexp_replace(v_ph,'[^0-9]','','g'))<9 or coalesce(trim(p->>'name'),'')='' then raise exception 'bad'; end if;
  if (select count(*) from fw_rec where col='I' and updated_at>now()-interval '10 minutes')>=15 then raise exception 'busy'; end if;
  insert into fw_rec(col,id,data,sid,updated_at) values('I',v_id,jsonb_build_object(
    'id',v_id,'status','new','at',to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI'),
    'name',left(trim(p->>'name'),20),'parent',v_ph,'school',left(coalesce(p->>'school',''),30),
    'grade',left(coalesce(p->>'grade',''),15),'msg',left(coalesce(p->>'msg',''),600)),null,clock_timestamp());
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.fw_inquiry(jsonb) to anon, authenticated;

select 'OK' as result;
