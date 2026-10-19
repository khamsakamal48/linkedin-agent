-- LinkedIn research store.
-- One parent row per person, one child row per job / degree: a profile with
-- 2 jobs and one with 30 jobs use the same schema. `raw` keeps the scraped
-- text so rows can be re-derived without visiting LinkedIn again.

create schema if not exists linkedin;

create table if not exists linkedin.person (
  id               bigserial primary key,
  linkedin_url     text unique not null,
  public_id        text,
  full_name        text,
  headline         text,
  location         text,
  about            text,
  current_company  text,
  current_title    text,
  raw              jsonb not null,
  scraped_at       timestamptz not null default now(),
  source           text
);

create table if not exists linkedin.employment (
  id                    bigserial primary key,
  person_id             bigint not null references linkedin.person on delete cascade,
  position              smallint,
  company_name          text,
  company_linkedin_url  text,
  title                 text,
  employment_type       text,
  location              text,
  start_date            date,
  end_date              date,
  is_current            boolean,
  description           text
);

create table if not exists linkedin.education (
  id                   bigserial primary key,
  person_id            bigint not null references linkedin.person on delete cascade,
  position             smallint,
  school               text,
  school_linkedin_url  text,
  degree               text,
  field_of_study       text,
  start_year           int,
  end_year             int
);

create table if not exists linkedin.csr_lead (
  id            bigserial primary key,
  company_name  text not null,
  company_cin   text,
  person_id     bigint references linkedin.person,
  linkedin_url  text,
  salesnav_url  text not null,
  full_name     text,
  title         text,
  location      text,
  match_reason  text,
  score         smallint,
  found_at      timestamptz not null default now(),
  unique (company_name, salesnav_url)
);

create table if not exists linkedin.scrape_log (
  id       bigserial primary key,
  account  text not null,
  tool     text not null,
  target   text,
  ok       boolean not null,
  error    text,
  at       timestamptz not null default now()
);

create index if not exists employment_company_idx on linkedin.employment (lower(company_name));
create index if not exists employment_person_idx  on linkedin.employment (person_id);
create index if not exists education_person_idx   on linkedin.education (person_id);
create index if not exists person_raw_idx         on linkedin.person using gin (raw);
create index if not exists scrape_log_day_idx     on linkedin.scrape_log (account, tool, at);

-- Normalise any LinkedIn profile URL / username to https://www.linkedin.com/in/<id>/
create or replace function linkedin.canonical_url(p text) returns text
language sql immutable as $$
  select 'https://www.linkedin.com/in/' ||
         lower(coalesce(substring(p from '/in/([^/?#]+)'), trim(both '/' from p))) || '/'
$$;

-- Lenient date parse: '2021', '2021-03', '2021-03-01' -> date; anything else -> null.
create or replace function linkedin.to_date(p text) returns date
language sql immutable as $$
  select case
    when p ~ '^\d{4}-\d{2}-\d{2}$' then p::date
    when p ~ '^\d{4}-\d{2}$'       then (p || '-01')::date
    when p ~ '^\d{4}$'             then (p || '-01-01')::date
  end
$$;

-- Cache check: returns the stored profile if it is younger than max_age_days, else no rows.
create or replace function linkedin.fresh_profile(p_url text, max_age_days int default 90)
returns table (person_id bigint, scraped_at timestamptz, profile jsonb)
language sql stable as $$
  select p.id, p.scraped_at,
    jsonb_build_object(
      'linkedin_url', p.linkedin_url, 'full_name', p.full_name, 'headline', p.headline,
      'location', p.location, 'about', p.about,
      'current_company', p.current_company, 'current_title', p.current_title,
      'employment', coalesce((select jsonb_agg(to_jsonb(e) - 'id' - 'person_id' order by e.position)
                              from linkedin.employment e where e.person_id = p.id), '[]'),
      'education',  coalesce((select jsonb_agg(to_jsonb(d) - 'id' - 'person_id' order by d.position)
                              from linkedin.education d where d.person_id = p.id), '[]'))
  from linkedin.person p
  where p.linkedin_url = linkedin.canonical_url(p_url)
    and p.scraped_at > now() - make_interval(days => max_age_days)
$$;

-- Daily budget per account+tool, counted from scrape_log.
create or replace function linkedin.under_daily_cap(p_account text, p_tool text, p_cap int)
returns boolean language sql stable as $$
  select count(*) < p_cap from linkedin.scrape_log
  where account = p_account and tool = p_tool and ok and at > date_trunc('day', now())
$$;

-- Upsert one profile in one transaction. Child rows are replaced, so a
-- re-scrape never duplicates jobs. Input shape (from the extraction step):
-- { linkedin_url, full_name, headline, location, about, current_company, current_title,
--   employment: [{company_name, company_linkedin_url, title, employment_type, location,
--                 start_date, end_date, is_current, description}],
--   education:  [{school, school_linkedin_url, degree, field_of_study, start_year, end_year}],
--   raw: {...}, source }
create or replace function linkedin.upsert_profile(p jsonb) returns bigint
language plpgsql as $$
declare pid bigint;
begin
  if coalesce(p->>'linkedin_url', '') = '' then
    raise exception 'upsert_profile: linkedin_url missing';
  end if;

  insert into linkedin.person as t (linkedin_url, public_id, full_name, headline, location, about,
                                    current_company, current_title, raw, source, scraped_at)
  values (linkedin.canonical_url(p->>'linkedin_url'),
          substring(p->>'linkedin_url' from '/in/([^/?#]+)'),
          p->>'full_name', p->>'headline', p->>'location', p->>'about',
          p->>'current_company', p->>'current_title',
          coalesce(p->'raw', '{}'), p->>'source', now())
  on conflict (linkedin_url) do update set
    full_name = excluded.full_name, headline = excluded.headline, location = excluded.location,
    about = excluded.about, current_company = excluded.current_company,
    current_title = excluded.current_title, raw = excluded.raw, source = excluded.source,
    scraped_at = now()
  returning id into pid;

  delete from linkedin.employment where person_id = pid;
  delete from linkedin.education  where person_id = pid;

  insert into linkedin.employment (person_id, position, company_name, company_linkedin_url, title,
                                   employment_type, location, start_date, end_date, is_current, description)
  select pid, ord, e->>'company_name', e->>'company_linkedin_url', e->>'title',
         e->>'employment_type', e->>'location',
         linkedin.to_date(e->>'start_date'), linkedin.to_date(e->>'end_date'),
         (e->>'is_current')::boolean, e->>'description'
  from jsonb_array_elements(coalesce(p->'employment', '[]')) with ordinality as x(e, ord);

  insert into linkedin.education (person_id, position, school, school_linkedin_url, degree,
                                  field_of_study, start_year, end_year)
  select pid, ord, d->>'school', d->>'school_linkedin_url', d->>'degree', d->>'field_of_study',
         nullif(d->>'start_year', '')::int, nullif(d->>'end_year', '')::int
  from jsonb_array_elements(coalesce(p->'education', '[]')) with ordinality as x(d, ord);

  return pid;
end $$;

-- Insert ranked Sales Navigator leads; re-running for the same company refreshes them.
-- leads: [{fullName, title, location, salesNavUrl, score, match_reason}]
create or replace function linkedin.add_csr_leads(p_company text, p_cin text, leads jsonb)
returns int language sql as $$
  with ins as (
    insert into linkedin.csr_lead (company_name, company_cin, salesnav_url, full_name, title,
                                   location, score, match_reason)
    select p_company, nullif(p_cin, ''), l->>'salesNavUrl', l->>'fullName', l->>'title',
           l->>'location', nullif(l->>'score', '')::smallint, l->>'match_reason'
    from jsonb_array_elements(leads) l
    where coalesce(l->>'salesNavUrl', '') <> ''
    on conflict (company_name, salesnav_url) do update set
      title = excluded.title, score = excluded.score, match_reason = excluded.match_reason,
      company_cin = coalesce(excluded.company_cin, linkedin.csr_lead.company_cin), found_at = now()
    returning 1)
  select count(*)::int from ins
$$;
