-- ═══════════════════════════════════════════════════════════════
-- FocusFlow — Supabase Schema
-- Run this entire file in: Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Users (mirrors Supabase auth.users) ───────────────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text unique not null,
  name        text,
  avatar_url  text,
  created_at  timestamptz default now()
);

-- ── 2. Daily focus stats ──────────────────────────────────────
create table if not exists public.daily_stats (
  id            bigserial primary key,
  user_id       uuid references public.profiles(id) on delete cascade,
  date          date not null,
  sessions      int default 0,
  focus_minutes int default 0,
  tasks_done    int default 0,
  unique(user_id, date)
);

-- ── 3. Streaks ────────────────────────────────────────────────
create table if not exists public.streaks (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  current        int default 0,
  longest        int default 0,
  last_active    date,
  updated_at     timestamptz default now()
);

-- ── 4. Friendships ────────────────────────────────────────────
-- status: 'pending' | 'accepted'
create table if not exists public.friendships (
  id          bigserial primary key,
  requester   uuid references public.profiles(id) on delete cascade,
  addressee   uuid references public.profiles(id) on delete cascade,
  status      text default 'pending',
  created_at  timestamptz default now(),
  unique(requester, addressee)
);

-- ═══════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- ═══════════════════════════════════════════════════════════════
alter table public.profiles    enable row level security;
alter table public.daily_stats enable row level security;
alter table public.streaks     enable row level security;
alter table public.friendships enable row level security;

-- profiles: anyone can read, only owner can update
create policy "profiles_read"   on public.profiles for select using (true);
create policy "profiles_insert" on public.profiles for insert with check (auth.uid() = id);
create policy "profiles_update" on public.profiles for update using (auth.uid() = id);

-- daily_stats: owner full access; friends can read
create policy "stats_owner"   on public.daily_stats for all    using (auth.uid() = user_id);
create policy "stats_friends" on public.daily_stats for select using (
  exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
    and ((f.requester = auth.uid() and f.addressee = user_id)
      or (f.addressee = auth.uid() and f.requester = user_id))
  )
);

-- streaks: anyone can read (for leaderboard), owner can write
create policy "streaks_read"   on public.streaks for select using (true);
create policy "streaks_write"  on public.streaks for all    using (auth.uid() = user_id);

-- friendships: users can see their own rows, insert their own requests
create policy "friends_read"   on public.friendships for select using (auth.uid() = requester or auth.uid() = addressee);
create policy "friends_insert" on public.friendships for insert with check (auth.uid() = requester);
create policy "friends_update" on public.friendships for update using (auth.uid() = addressee);
create policy "friends_delete" on public.friendships for delete using (auth.uid() = requester or auth.uid() = addressee);

-- ═══════════════════════════════════════════════════════════════
-- FUNCTIONS
-- ═══════════════════════════════════════════════════════════════

-- Auto-create profile + streak row when user signs up via Google OAuth
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;

  insert into public.streaks (user_id, current, longest, last_active)
  values (new.id, 0, 0, null)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

-- Trigger: fires on every new auth signup
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Recalculate streak for a user (call after upserting daily_stats)
create or replace function public.recalculate_streak(p_user_id uuid)
returns void language plpgsql security definer as $$
declare
  v_streak   int := 0;
  v_longest  int := 0;
  v_check    date := current_date;
  v_date     date;
begin
  -- Walk backwards from today counting consecutive active days
  for v_date in
    select date from public.daily_stats
    where user_id = p_user_id and sessions > 0
    order by date desc
  loop
    if v_date = v_check or v_date = v_check - 1 then
      v_streak := v_streak + 1;
      v_check  := v_date;
    else
      exit;
    end if;
  end loop;

  select coalesce(max(longest), 0) into v_longest
  from public.streaks where user_id = p_user_id;

  update public.streaks
  set current     = v_streak,
      longest     = greatest(v_longest, v_streak),
      last_active = current_date,
      updated_at  = now()
  where user_id = p_user_id;
end;
$$;

-- ═══════════════════════════════════════════════════════════════
-- LEADERBOARD VIEW (friends + self, ranked by streak)
-- ═══════════════════════════════════════════════════════════════
create or replace view public.leaderboard as
select
  p.id,
  p.name,
  p.avatar_url,
  s.current  as streak,
  s.longest  as longest_streak,
  coalesce(sum(ds.focus_minutes), 0) as total_focus_minutes,
  coalesce(sum(ds.sessions), 0)      as total_sessions,
  coalesce(sum(ds.tasks_done), 0)    as total_tasks
from public.profiles p
join public.streaks s on s.user_id = p.id
left join public.daily_stats ds on ds.user_id = p.id
group by p.id, p.name, p.avatar_url, s.current, s.longest
order by s.current desc;
