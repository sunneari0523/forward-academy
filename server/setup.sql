-- 포워드 학습관리 서버 설정 (Supabase SQL Editor에서 한 번 실행)

create table if not exists public.fw_rec(
  col text not null, id text not null, data jsonb, sid text,
  updated_at timestamptz not null default clock_timestamp(),
  primary key(col,id));
create index if not exists fw_rec_upd on public.fw_rec(updated_at);
create table if not exists public.fw_sess(
  token uuid primary key default gen_random_uuid(),
  role text not null, uid text not null,
  created_at timestamptz not null default now());
create table if not exists public.fw_fail(at timestamptz not null default now());
alter table public.fw_rec enable row level security;
alter table public.fw_sess enable row level security;
alter table public.fw_fail enable row level security;
revoke all on public.fw_rec, public.fw_sess, public.fw_fail from anon, authenticated;

-- 세션 확인 (삭제된 학생/강사는 자동으로 로그아웃)
create or replace function public.fw_who(p_token uuid) returns public.fw_sess
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess;
begin
  select * into s from fw_sess where token=p_token;
  if s.token is null then raise exception 'auth'; end if;
  if not exists(select 1 from fw_rec where col=case when s.role='student' then 'S' else 'T' end and id=s.uid and data is not null)
  then delete from fw_sess where token=p_token; raise exception 'auth'; end if;
  return s;
end $$;

-- 로그인. 처음(강사 0명)에는 원장 로그인으로 원장 계정이 만들어짐
create or replace function public.fw_login(p_role text, p_name text, p_secret text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_id text; v_role text; v_tok uuid;
begin
  if (select count(*) from fw_fail where at>now()-interval '10 minutes')>60 then
    raise exception '로그인 시도가 너무 많아요. 10분 뒤에 다시 해주세요'; end if;
  if coalesce(p_name,'')='' or coalesce(p_secret,'')='' then raise exception '이름과 코드를 입력해 주세요'; end if;
  if p_role='student' then
    select id into v_id from fw_rec where col='S' and data is not null
      and data->>'name'=p_name and data->>'code'=p_secret limit 1;
    v_role:='student';
  else
    if p_role='owner' and not exists(select 1 from fw_rec where col='T' and data is not null) then
      v_id:='t0';
      insert into fw_rec(col,id,data,sid) values('T','t0',jsonb_build_object('id','t0','name',p_name,'role','owner','pw',p_secret),'t0')
      on conflict(col,id) do update set data=excluded.data, updated_at=clock_timestamp();
    else
      select id into v_id from fw_rec where col='T' and data is not null and data->>'name'=p_name and data->>'pw'=p_secret
        and (data->>'role'='owner')=(p_role='owner') limit 1;
    end if;
    v_role:=p_role;
  end if;
  if v_id is null then
    insert into fw_fail default values; delete from fw_fail where at<now()-interval '1 day';
    perform pg_sleep(0.4); return null;
  end if;
  insert into fw_sess(role,uid) values(v_role,v_id) returning token into v_tok;
  return jsonb_build_object('token',v_tok,'role',v_role,'id',v_id);
end $$;

create or replace function public.fw_logout(p_token uuid) returns void
language sql security definer set search_path=public as $$ delete from fw_sess where token=p_token $$;

-- 데이터 받기 (학생은 자기 것만)
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
    and (s.role<>'student' or r.col in ('T','C','E','meta') or r.sid=s.uid);
  return jsonb_build_object('now',v_now,'rows',v_rows);
end $$;

-- 데이터 저장 (학생은 자기 숙제·질문·성적·콩떡이만)
create or replace function public.fw_push(p_token uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; x jsonb; v_col text; v_id text; v_data jsonb; v_sid text; v_old public.fw_rec; n int:=0;
begin
  s:=fw_who(p_token);
  for x in select * from jsonb_array_elements(p_rows) loop
    v_col:=x->>'col'; v_id:=x->>'id'; v_data:=case when jsonb_typeof(x->'data')='object' then x->'data' end;
    select * into v_old from fw_rec where col=v_col and id=v_id;
    v_sid:=case when v_col in ('S','P','T') then v_id when v_data is not null then v_data->>'sid' else v_old.sid end;
    if s.role='student' then
      continue when v_data is null;
      continue when not ((v_col in ('tasks','R','Q') and v_sid=s.uid and (v_old.sid is null or v_old.sid=s.uid))
                         or (v_col='P' and v_id=s.uid));
    end if;
    if v_col='T' and v_data is not null and not v_data ? 'pw' and v_old.data ? 'pw' then
      v_data:=v_data||jsonb_build_object('pw',v_old.data->'pw'); end if;
    if v_col='E' and v_data is not null and s.role='student' then continue; end if;
    insert into fw_rec(col,id,data,sid,updated_at) values(v_col,v_id,v_data,v_sid,clock_timestamp())
    on conflict(col,id) do update set data=excluded.data, sid=excluded.sid, updated_at=clock_timestamp();
    n:=n+1;
  end loop;
  return jsonb_build_object('saved',n);
end $$;

-- 사진 업로드 허가: 로그인한 사람만 (폴더 이름 = 토큰의 해시)
create or replace function public.fw_upload_ok(p_folder text) returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from fw_sess where encode(sha256(convert_to(token::text,'UTF8')),'hex')=p_folder) $$;

revoke all on function public.fw_who(uuid) from public, anon, authenticated;
grant execute on function public.fw_login(text,text,text), public.fw_logout(uuid),
  public.fw_pull(uuid,timestamptz), public.fw_push(uuid,jsonb), public.fw_upload_ok(text) to anon, authenticated;

insert into storage.buckets(id,name,public) values('hw','hw',true) on conflict(id) do nothing;
drop policy if exists fw_hw_insert on storage.objects;
create policy fw_hw_insert on storage.objects for insert to anon, authenticated
  with check (bucket_id='hw' and public.fw_upload_ok((storage.foldername(name))[1]));

select 'OK 설정 완료' as result;
