-- 원장·강사 로그인 탭 합치기 (예전 'owner'/'teacher' 방식도 그대로 동작)
-- 로그인: 원장·강사는 한 탭(p_role='staff')으로 — 계정에 저장된 역할(원장/강사)로 들어감
-- 학부모는 p_name=학생 이름, p_secret=등록 연도+학부모 휴대폰 가운데 번호
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
  elsif p_role='staff' then
    select id, data->>'role' into v_id, v_role from fw_rec where col='T' and data is not null
      and data->>'name'=trim(p_name) and data->>'pw'=p_secret
      order by (data->>'role'='owner') desc limit 1;
    if v_role is distinct from 'owner' then v_role:='teacher'; end if;
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

select 'OK 강사 로그인 합치기 완료' as result;
