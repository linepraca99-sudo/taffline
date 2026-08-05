-- ============================================================
-- SCHEMA TAFFLINE — à coller dans Supabase > SQL Editor > Run
-- ============================================================

-- 1) PROFILS UTILISATEURS
-- Chaque utilisateur (créé automatiquement par Supabase Auth lors de
-- l'inscription) a un profil complémentaire ici, avec son rôle.
create table profiles (
  id uuid references auth.users on delete cascade primary key,
  role text not null check (role in ('candidat', 'recruteur')),
  nom_complet text not null,
  entreprise text,              -- rempli seulement si role = 'recruteur'
  telephone text,
  cv_url text,                  -- lien vers un CV uploadé (candidats)
  niveau_etude text,            -- candidats : "Aucun", "CAP/BEP", "Bac", "Bac+2", "Bac+3", "Bac+5", "Bac+8"
  created_at timestamptz default now()
);

alter table profiles enable row level security;

-- Tout le monde peut voir les profils publics (utile pour afficher le nom du recruteur sur une offre)
create policy "Profils visibles par tous"
  on profiles for select
  using (true);

-- Chacun ne peut modifier que SON PROPRE profil
create policy "Modifier son propre profil"
  on profiles for update
  using (auth.uid() = id);

-- Le profil est créé automatiquement à l'inscription (voir trigger plus bas)
create policy "Création de profil à l'inscription"
  on profiles for insert
  with check (auth.uid() = id);


-- 2) OFFRES D'EMPLOI
create table jobs (
  id uuid default gen_random_uuid() primary key,
  recruteur_id uuid references profiles(id) on delete cascade not null,
  titre text not null,
  entreprise text not null,
  description text not null,
  localisation text not null,
  type_contrat text not null check (type_contrat in ('CDI', 'CDD', 'Intérim', 'Alternance', 'Stage', 'Freelance')),
  salaire_min integer,
  salaire_max integer,
  diplome_requis text,          -- "Aucun", "CAP/BEP", "Bac", "Bac+2", "Bac+3", "Bac+5", "Bac+8"
  secteur text,                 -- "BTP", "Restauration", "Informatique", "Santé", "Commerce", "Transport", "Industrie", "Autre"
  experience_requise text,      -- "Débutant accepté", "1-3 ans", "3-5 ans", "5 ans et plus"
  teletravail text default 'Sur site' check (teletravail in ('Sur site', 'Hybride', '100% télétravail')),
  is_active boolean default true,
  created_at timestamptz default now()
);

alter table jobs enable row level security;

-- Les offres actives sont visibles par tout le monde (même sans compte)
create policy "Offres actives visibles par tous"
  on jobs for select
  using (is_active = true);

-- Seul le recruteur qui a créé l'offre peut la voir même si désactivée, la modifier ou la supprimer
create policy "Recruteur gère ses propres offres (lecture)"
  on jobs for select
  using (auth.uid() = recruteur_id);

create policy "Recruteur crée une offre"
  on jobs for insert
  with check (
    auth.uid() = recruteur_id
    and exists (select 1 from profiles where id = auth.uid() and role = 'recruteur')
  );

create policy "Recruteur modifie ses offres"
  on jobs for update
  using (auth.uid() = recruteur_id);

create policy "Recruteur supprime ses offres"
  on jobs for delete
  using (auth.uid() = recruteur_id);


-- 3) CANDIDATURES
create table applications (
  id uuid default gen_random_uuid() primary key,
  job_id uuid references jobs(id) on delete cascade not null,
  candidat_id uuid references profiles(id) on delete cascade not null,
  message text,
  statut text default 'envoyée' check (statut in ('envoyée', 'vue', 'acceptée', 'refusée')),
  created_at timestamptz default now(),
  unique (job_id, candidat_id) -- un candidat ne peut postuler qu'une fois à la même offre
);

alter table applications enable row level security;

-- Le candidat voit ses propres candidatures
create policy "Candidat voit ses candidatures"
  on applications for select
  using (auth.uid() = candidat_id);

-- Le recruteur voit les candidatures reçues sur SES offres
create policy "Recruteur voit les candidatures de ses offres"
  on applications for select
  using (
    exists (select 1 from jobs where jobs.id = job_id and jobs.recruteur_id = auth.uid())
  );

-- Un candidat peut postuler
create policy "Candidat postule"
  on applications for insert
  with check (
    auth.uid() = candidat_id
    and exists (select 1 from profiles where id = auth.uid() and role = 'candidat')
  );

-- Le recruteur peut changer le statut (vue / acceptée / refusée) sur ses offres
create policy "Recruteur met à jour le statut"
  on applications for update
  using (
    exists (select 1 from jobs where jobs.id = job_id and jobs.recruteur_id = auth.uid())
  );


-- 4) FAVORIS (candidats qui sauvegardent une offre)
create table favorites (
  id uuid default gen_random_uuid() primary key,
  candidat_id uuid references profiles(id) on delete cascade not null,
  job_id uuid references jobs(id) on delete cascade not null,
  created_at timestamptz default now(),
  unique (candidat_id, job_id)
);

alter table favorites enable row level security;

create policy "Candidat gère ses favoris"
  on favorites for all
  using (auth.uid() = candidat_id)
  with check (auth.uid() = candidat_id);


-- 5) STOCKAGE DES CV
-- Crée un bucket "cvs" pour que les candidats uploadent leur CV en PDF.
insert into storage.buckets (id, name, public)
values ('cvs', 'cvs', true)
on conflict (id) do nothing;

-- Chacun peut uploader UNIQUEMENT dans son propre dossier (nommé avec son user id)
create policy "Upload de son propre CV"
  on storage.objects for insert
  with check (
    bucket_id = 'cvs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "Remplacer son propre CV"
  on storage.objects for update
  using (
    bucket_id = 'cvs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "CV publiquement lisibles"
  on storage.objects for select
  using (bucket_id = 'cvs');


-- 6) CRÉATION AUTOMATIQUE DU PROFIL À L'INSCRIPTION
-- Quand quelqu'un s'inscrit (auth.users), on lit les infos passées lors du
-- signUp() (voir "options.data" côté site) pour remplir la table profiles.
create function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, role, nom_complet, entreprise, niveau_etude)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'role', 'candidat'),
    coalesce(new.raw_user_meta_data->>'nom_complet', ''),
    new.raw_user_meta_data->>'entreprise',
    new.raw_user_meta_data->>'niveau_etude'
  );
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- 7) INDEX pour des recherches rapides
create index jobs_localisation_idx on jobs (localisation);
create index jobs_type_contrat_idx on jobs (type_contrat);
create index jobs_created_at_idx on jobs (created_at desc);
create index jobs_secteur_idx on jobs (secteur);
create index jobs_diplome_idx on jobs (diplome_requis);
create index applications_job_id_idx on applications (job_id);
create index applications_candidat_id_idx on applications (candidat_id);
