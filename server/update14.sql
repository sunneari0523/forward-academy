-- 학부모 계정(PA) + 학부모 댓글(PM)
-- 학부모: 휴대폰 번호 + 비밀번호로 로그인, 자기 자녀의 숙제·단어 시험·수업 일지만 볼 수 있음 (고치기 불가)
--         댓글(PM)만 자기 이름으로 쓰고 지울 수 있음
-- 학생에게는 학부모 계정·댓글이 안 보임

-- 세션 확인: 학부모는 PA에 계정이 있어야 함
create or replace function public.fw_who(p_token uuid) returns public.fw_sess
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess;
begin
  select * into s from fw_sess where token=p_token;
  if s.token is null then raise exception 'auth'; end if;
  if not exists(select 1 from fw_rec where col=case when s.role='student' then 'S' when s.role='parent' then 'PA' else 'T' end
                and id=s.uid and data is not null)
  then delete from fw_sess where token=p_token; raise exception 'auth'; end if;
  return s;
end $$;
revoke all on function public.fw_who(uuid) from public, anon, authenticated;

-- 로그인: 학부모는 p_name=휴대폰 번호, p_secret=비밀번호
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
    if length(regexp_replace(p_name,'[^0-9]','','g'))>=9 then
      select id into v_id from fw_rec where col='PA' and data is not null
        and regexp_replace(coalesce(data->>'phone',''),'[^0-9]','','g')=regexp_replace(p_name,'[^0-9]','','g')
        and data->>'pw'=p_secret limit 1;
    end if;
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
    select coalesce(data->'kids','[]'::jsonb) into v_kids from fw_rec where col='PA' and id=s.uid;
    select coalesce(jsonb_agg(jsonb_build_object('col',r.col,'id',r.id,'data',
      case
        when r.data is null then null
        when r.col='PA' then r.data-'pw'
        when r.col='S' then jsonb_build_object('id',r.id,'name',r.data->'name','school',r.data->'school','grade',r.data->'grade',
                                               'tid',r.data->'tid','cid',r.data->'cid','grad',r.data->'grad')
        when r.col='T' then jsonb_build_object('id',r.id,'name',r.data->'name','role',r.data->'role')
        else r.data end)),'[]'::jsonb)
    into v_rows
    from fw_rec r
    where (p_since is null and r.data is not null or r.updated_at>p_since)
      and ((r.col='PA' and r.id=s.uid)
        or (r.col='S' and v_kids ? r.id)
        or (r.col in ('tasks','L','PM') and v_kids ? r.sid)
        or (r.col='R' and v_kids ? r.sid and (r.data is null or r.data ? 'voca'))
        or (r.col='C' and r.data is not null)
        or r.col='T');
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
    and (s.role<>'student' or (r.col not in ('N','L','PC','M','I','PA','PM') and (r.col in ('T','C','E','meta') or r.sid=s.uid)))
    and (r.col<>'RS' or r.sid=s.uid)
    and (r.col<>'M' or r.data is null or r.data->>'room'='all' or r.data->>'by'=s.uid or coalesce(r.data->'to','[]'::jsonb) ? s.uid);
  return jsonb_build_object('now',v_now,'rows',v_rows);
end $$;

-- 데이터 저장: 학부모는 자녀에 대한 자기 댓글(PM)만
create or replace function public.fw_push(p_token uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; x jsonb; v_col text; v_id text; v_data jsonb; v_sid text; v_old public.fw_rec; n int:=0; v_kids jsonb;
begin
  s:=fw_who(p_token);
  if s.role='parent' then select coalesce(data->'kids','[]'::jsonb) into v_kids from fw_rec where col='PA' and id=s.uid; end if;
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
        v_data:=v_data||jsonb_build_object('by',s.uid,'role','parent');
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

select 'OK 학부모 계정 설정 완료' as result;
