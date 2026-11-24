-- 학부모 로그인 + 학부모 댓글(PM)
-- 학부모: 아이디 = 학생 이름, 비밀번호 = 등록 연도(학생코드 앞 4자리) + 학부모 휴대폰 가운데 번호
--         (학생 정보의 '학부모 연락처'로 자동 확인 — 따로 계정을 만들 필요 없음)
--         같은 학부모 번호를 가진 형제·자매를 한꺼번에 볼 수 있음. 숙제·단어 시험·수업 일지는 보기만,
--         댓글(PM)만 쓰고 자기 댓글만 지울 수 있음
-- 학생에게는 학부모 댓글이 안 보임

create or replace function public.fw_digits(t text) returns text
language sql immutable as $$ select regexp_replace(coalesce(t,''),'[^0-9]','','g') $$;

-- 학부모 세션 uid = 'pp' + 학부모 휴대폰 숫자
create or replace function public.fw_pkids(p_uid text) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(id),'[]'::jsonb) from fw_rec
  where col='S' and data is not null and length(substr(p_uid,3))>=10 and fw_digits(data->>'parent')=substr(p_uid,3) $$;
revoke all on function public.fw_pkids(text) from public, anon, authenticated;

-- 세션 확인
create or replace function public.fw_who(p_token uuid) returns public.fw_sess
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess;
begin
  select * into s from fw_sess where token=p_token;
  if s.token is null then raise exception 'auth'; end if;
  if s.role='parent' then
    if jsonb_array_length(fw_pkids(s.uid))=0 then delete from fw_sess where token=p_token; raise exception 'auth'; end if;
    return s;
  end if;
  if not exists(select 1 from fw_rec where col=case when s.role='student' then 'S' else 'T' end and id=s.uid and data is not null)
  then delete from fw_sess where token=p_token; raise exception 'auth'; end if;
  return s;
end $$;
revoke all on function public.fw_who(uuid) from public, anon, authenticated;

-- 로그인: 학부모는 p_name=학생 이름, p_secret=등록 연도+학부모 휴대폰 가운데 번호
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
  elsif p_role='parent' then
    select 'pp'||fw_digits(data->>'parent') into v_id from fw_rec where col='S' and data is not null
      and data->>'name'=trim(p_name) and length(fw_digits(data->>'parent'))>=10
      and left(coalesce(nullif(data->>'code',''),'2026'),4)||substr(fw_digits(data->>'parent'),4,length(fw_digits(data->>'parent'))-7)=trim(p_secret)
      limit 1;
    v_role:='parent';
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

-- 데이터 받기: 학부모는 자녀 것만, 학생은 학부모 계정·댓글 못 봄
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
    -- 학부모 정보(PA)는 저장하지 않고 매번 만들어서 보냄
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
      else r.data end)),'[]'::jsonb)
  into v_rows
  from fw_rec r
  where (p_since is null and r.data is not null or r.updated_at>p_since)
    and (s.role<>'student' or (r.col not in ('N','L','PC','M','I','PM') and (r.col in ('T','C','E','meta') or r.sid=s.uid)))
    and (r.col<>'RS' or r.sid=s.uid)
    and (r.col<>'M' or r.data is null or r.data->>'room'='all' or r.data->>'by'=s.uid or coalesce(r.data->'to','[]'::jsonb) ? s.uid);
  return jsonb_build_object('now',v_now,'rows',v_rows);
end $$;

-- 데이터 저장: 학부모는 자녀에 대한 자기 댓글(PM)만
create or replace function public.fw_push(p_token uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; x jsonb; v_col text; v_id text; v_data jsonb; v_sid text; v_old public.fw_rec; n int:=0; v_kids jsonb; v_pname text;
begin
  s:=fw_who(p_token);
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
    if v_col='RS' and v_id<>s.uid then continue; end if;
    if v_col='RS' and v_data is not null then v_data:=v_data||jsonb_build_object('sid',s.uid); v_sid:=s.uid; end if;
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

grant execute on function public.fw_login(text,text,text), public.fw_pull(uuid,timestamptz), public.fw_push(uuid,jsonb) to anon, authenticated;

select 'OK 학부모 로그인 설정 완료' as result;
