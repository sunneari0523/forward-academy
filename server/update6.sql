-- 알림(웹 푸시) 받는 기기 목록 + 설정 저장 (서버 함수 notify만 사용)
create table if not exists public.fw_push_subs(endpoint text primary key, uid text not null, role text, sub jsonb not null, at timestamptz default now());
create table if not exists public.fw_conf(k text primary key, v jsonb);
alter table public.fw_push_subs enable row level security;
alter table public.fw_conf enable row level security;
revoke all on public.fw_push_subs, public.fw_conf from anon, authenticated;
select 'OK' as result;
