-- =====================================================================
--  HADIRKUY · Absensi Digital Siswa · MAN 1 BOALEMO
--  FASE 1 + 2 + 3 — Supabase SQL (satu file)
--
--  AMAN DIJALANKAN ULANG: dipakai untuk instalasi baru MAUPUN upgrade
--  dari Fase 1 (data lama tetap utuh). Jalankan di SQL Editor.
--
--  Isi Fase 1:
--   • Login NISN/username + kata sandi (bcrypt), sesi berbasis token,
--     kunci 10 menit setelah 5x gagal, wajib ganti sandi awal.
--   • QR dinamis bertanda tangan HMAC, berganti tiap N detik.
--   • Jam absen dicatat oleh SERVER (bukan jam HP siswa).
--   • Geofence: jarak ke madrasah dihitung di server (Haversine);
--     yang disimpan hanya "dalam radius: ya/tidak", bukan koordinat.
--   • Aturan terlambat, jam buka/tutup, jam pulang (termasuk Jumat),
--     hari sekolah & hari libur — semua bisa diatur admin.
--   • Rekap harian/bulanan, riwayat pribadi, koreksi manual oleh
--     wali kelas/admin.
--
--  Isi Fase 2:
--   • Pengajuan izin/sakit online + foto bukti, disetujui wali kelas.
--   • Cek perasaan setelah absen masuk (hanya dilihat wali kelas & BK)
--     dan pilihan "ingin bercerita dengan guru BK".
--   • Kunci perangkat: satu akun = satu HP, satu HP = satu absen/hari
--     (mencegah titip absen). Wali/admin dapat mereset perangkat.
--   • Notifikasi WhatsApp ke orang tua (Fonnte via pg_net) + antrean
--     manual (tombol buka WhatsApp) bila gateway belum diaktifkan.
--   • "Perlu Disapa": peringatan dini (alpa beruntun, sering terlambat,
--     perasaan rendah, ingin bercerita) + catatan tindak lanjut.
--
--  Isi Fase 3:
--   • Kartu QR Siswa + Pos Petugas: untuk siswa tanpa HP (petugas memindai
--     kartu di gerbang), plus pencarian manual oleh petugas.
--   • Absen offline: QR yang dipindai tanpa sinyal disimpan di HP dan dikirim
--     belakangan; waktu absen diambil dari QR (bukan jam HP).
--   • Dasbor kepala madrasah & dasbor wali kelas, matriks rekap bulanan
--     (unduh Excel / cetak), rekap S-I-A untuk rapor.
--
--  Tambahan: foto profil (unggah sendiri / oleh wali kelas), tampil di
--  Kartu QR dan Pos Scan untuk mencocokkan wajah siswa.
--
--  Semua tabel memakai awalan hk_ supaya AMAN dipasang di proyek
--  Supabase yang sama dengan EDUVERSE (tidak bentrok nama).
--  Akses data HANYA lewat fungsi RPC; tabel tertutup untuk anon (RLS).
--
--  Akun admin awal  →  username: admin   kata sandi: admin123
--  (wajib diganti saat pertama kali masuk)
--
--  Created by AN1MO LAB SQUAD
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- =====================================================================
-- 1. TABEL
-- =====================================================================

create table if not exists public.hk_pengaturan (
  id                 int primary key default 1 check (id = 1),
  nama_madrasah      text    not null default 'MAN 1 BOALEMO',
  zona_waktu         text    not null default 'Asia/Makassar',
  label_zona         text    not null default 'WITA',
  jam_buka_masuk     time    not null default '05:30',
  jam_masuk          time    not null default '07:15',
  toleransi_menit    int     not null default 0,
  jam_tutup_masuk    time    not null default '12:00',
  jam_pulang_min     time    not null default '14:00',
  jam_pulang_jumat   time             default '11:30',   -- kosongkan bila sama dengan hari lain
  jam_tutup_pulang   time    not null default '18:00',
  hari_sekolah       int[]   not null default '{1,2,3,4,5,6}', -- ISO: 1=Senin … 7=Minggu
  tanggal_mulai      date    not null default current_date,    -- alpa tidak dihitung sebelum tanggal ini
  wajib_lokasi       boolean not null default true,
  lat                double precision,
  lng                double precision,
  radius_m           int     not null default 150,
  qr_interval_detik  int     not null default 30,
  qr_rahasia         text    not null default encode(extensions.gen_random_bytes(32), 'hex')
);
insert into public.hk_pengaturan (id) values (1) on conflict (id) do nothing;

create table if not exists public.hk_kelas (
  id       bigint generated always as identity primary key,
  nama     text not null,
  wali_id  bigint,
  dibuat   timestamptz not null default now()
);
create unique index if not exists hk_kelas_nama_uq on public.hk_kelas (lower(nama));

create table if not exists public.hk_pengguna (
  id                    bigint generated always as identity primary key,
  username              text    not null,              -- NISN untuk siswa
  nama                  text    not null,
  peran                 text    not null check (peran in ('siswa','wali','bk','kepala','petugas','admin')),
  kelas_id              bigint  references public.hk_kelas(id) on delete set null,
  password_hash         text    not null,
  harus_ganti_password  boolean not null default true,
  aktif                 boolean not null default true,
  gagal_login           int     not null default 0,
  kunci_sampai          timestamptz,
  dibuat                timestamptz not null default now()
);
create unique index if not exists hk_pengguna_username_uq on public.hk_pengguna (lower(username));
create index if not exists hk_pengguna_kelas_idx on public.hk_pengguna (kelas_id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'hk_kelas_wali_fk') then
    alter table public.hk_kelas add constraint hk_kelas_wali_fk foreign key (wali_id)
      references public.hk_pengguna(id) on delete set null;
  end if;
end $$;

create table if not exists public.hk_sesi (
  token_hash   text primary key,
  pengguna_id  bigint not null references public.hk_pengguna(id) on delete cascade,
  kadaluarsa   timestamptz not null,
  dibuat       timestamptz not null default now()
);
create index if not exists hk_sesi_pengguna_idx on public.hk_sesi (pengguna_id);

create table if not exists public.hk_hari_libur (
  tanggal     date primary key,
  keterangan  text not null
);

create table if not exists public.hk_absensi (
  id                   bigint generated always as identity primary key,
  siswa_id             bigint not null references public.hk_pengguna(id) on delete cascade,
  tanggal              date   not null,
  jam_masuk            timestamptz,
  jam_pulang           timestamptz,
  status               text   not null check (status in ('hadir','terlambat','izin','sakit','alpa')),
  menit_terlambat      int    not null default 0,
  dalam_radius_masuk   boolean,
  dalam_radius_pulang  boolean,
  sumber               text   not null default 'qr' check (sumber in ('qr','manual')),
  keterangan           text,
  diubah_oleh          bigint references public.hk_pengguna(id) on delete set null,
  diubah               timestamptz not null default now(),
  unique (siswa_id, tanggal)
);
create index if not exists hk_absensi_tanggal_idx on public.hk_absensi (tanggal);

-- ---------- FASE 2: kolom tambahan ----------
alter table public.hk_pengaturan
  add column if not exists kunci_perangkat  boolean not null default true,
  add column if not exists wa_aktif         boolean not null default false,
  add column if not exists wa_token         text,
  add column if not exists notif_masuk      boolean not null default false,
  add column if not exists notif_terlambat  boolean not null default true,
  add column if not exists notif_pulang     boolean not null default false,
  add column if not exists notif_alpa       boolean not null default true,
  add column if not exists notif_izin       boolean not null default true;

alter table public.hk_pengguna
  add column if not exists no_wa_ortu         text,
  add column if not exists perangkat_hash     text,
  add column if not exists perangkat_terikat  timestamptz;

alter table public.hk_absensi
  add column if not exists perasaan       smallint check (perasaan between 1 and 5),
  add column if not exists ingin_cerita   boolean not null default false,
  add column if not exists perangkat_hash text,
  add column if not exists pengajuan_id   bigint;

create index if not exists hk_absensi_perangkat_idx on public.hk_absensi (tanggal, perangkat_hash);

-- ---------- FASE 3: kolom tambahan ----------
alter table public.hk_pengguna add column if not exists kartu_kode text;
create unique index if not exists hk_pengguna_kartu_uq on public.hk_pengguna (kartu_kode) where kartu_kode is not null;
alter table public.hk_absensi drop constraint if exists hk_absensi_sumber_check;
alter table public.hk_absensi add constraint hk_absensi_sumber_check
  check (sumber in ('qr', 'manual', 'pengajuan', 'kartu', 'pos'));

-- ---------- FOTO PROFIL ----------
create table if not exists public.hk_foto (
  pengguna_id    bigint primary key references public.hk_pengguna(id) on delete cascade,
  mime           text   not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
  data_b64       text   not null check (length(data_b64) <= 400000),
  oleh           bigint references public.hk_pengguna(id) on delete set null,
  terverifikasi  boolean not null default false,   -- true bila diunggah/diganti wali kelas atau admin
  diubah         timestamptz not null default now()
);

-- ---------- FASE 2: tabel baru ----------
create table if not exists public.hk_pengajuan (
  id            bigint generated always as identity primary key,
  siswa_id      bigint not null references public.hk_pengguna(id) on delete cascade,
  jenis         text   not null check (jenis in ('izin', 'sakit')),
  tgl_mulai     date   not null,
  tgl_selesai   date   not null,
  alasan        text   not null,
  status        text   not null default 'menunggu' check (status in ('menunggu', 'disetujui', 'ditolak', 'dibatalkan')),
  catatan_wali  text,
  diputus_oleh  bigint references public.hk_pengguna(id) on delete set null,
  diputus       timestamptz,
  dibuat        timestamptz not null default now(),
  check (tgl_selesai >= tgl_mulai)
);
create index if not exists hk_pengajuan_siswa_idx on public.hk_pengajuan (siswa_id, dibuat desc);
create index if not exists hk_pengajuan_status_idx on public.hk_pengajuan (status, dibuat desc);

-- Foto bukti disimpan terpisah (base64, sudah dikompres di HP) agar daftar tetap ringan
create table if not exists public.hk_lampiran (
  pengajuan_id  bigint primary key references public.hk_pengajuan(id) on delete cascade,
  mime          text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
  data_b64      text not null check (length(data_b64) <= 1400000)
);

create table if not exists public.hk_notifikasi (
  id         bigint generated always as identity primary key,
  siswa_id   bigint references public.hk_pengguna(id) on delete cascade,
  tanggal    date   not null,
  jenis      text   not null,   -- masuk | terlambat | pulang | alpa | pengajuan | izin_disetujui | izin_ditolak | uji
  ref        bigint not null default 0,
  tujuan     text   not null,   -- nomor WA (format 62…)
  pesan      text   not null,
  status     text   not null default 'antri' check (status in ('antri', 'diproses', 'terkirim', 'gagal', 'dibatalkan')),
  req_id     bigint,
  alasan     text,
  dibuat     timestamptz not null default now(),
  diubah     timestamptz not null default now(),
  unique (siswa_id, tanggal, jenis, ref)
);
create index if not exists hk_notifikasi_status_idx on public.hk_notifikasi (status, id);
create index if not exists hk_notifikasi_tanggal_idx on public.hk_notifikasi (tanggal desc);

create table if not exists public.hk_tindak_lanjut (
  id        bigint generated always as identity primary key,
  siswa_id  bigint not null references public.hk_pengguna(id) on delete cascade,
  oleh      bigint references public.hk_pengguna(id) on delete set null,
  jenis     text   not null check (jenis in ('sapaan', 'telepon_ortu', 'kunjungan_rumah', 'rujuk_bk', 'konseling', 'lainnya')),
  catatan   text   not null,
  dibuat    timestamptz not null default now()
);
create index if not exists hk_tindak_lanjut_siswa_idx on public.hk_tindak_lanjut (siswa_id, dibuat desc);

-- Tutup semua tabel dari akses langsung (hanya lewat RPC)
alter table public.hk_pengaturan    enable row level security;
alter table public.hk_kelas         enable row level security;
alter table public.hk_pengguna      enable row level security;
alter table public.hk_sesi          enable row level security;
alter table public.hk_hari_libur    enable row level security;
alter table public.hk_absensi       enable row level security;
alter table public.hk_pengajuan     enable row level security;
alter table public.hk_lampiran      enable row level security;
alter table public.hk_notifikasi    enable row level security;
alter table public.hk_tindak_lanjut enable row level security;
alter table public.hk_foto          enable row level security;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on public.hk_pengaturan, public.hk_kelas, public.hk_pengguna, public.hk_sesi,
                  public.hk_hari_libur, public.hk_absensi, public.hk_pengajuan, public.hk_lampiran,
                  public.hk_notifikasi, public.hk_tindak_lanjut, public.hk_foto
      from anon, authenticated;
  end if;
end $$;

-- Admin awal
insert into public.hk_pengguna (username, nama, peran, password_hash, harus_ganti_password)
select 'admin', 'Administrator', 'admin', extensions.crypt('admin123', extensions.gen_salt('bf', 8)), true
where not exists (select 1 from public.hk_pengguna where peran = 'admin');

-- =====================================================================
-- 2. FUNGSI BANTU (internal, awalan hk__ — tidak bisa dipanggil klien)
-- =====================================================================

create or replace function public.hk__hash(t text) returns text
language sql immutable set search_path = public, extensions as
$$ select encode(digest(t, 'sha256'), 'hex') $$;

create or replace function public.hk__cfg() returns public.hk_pengaturan
language sql stable set search_path = public as
$$ select * from hk_pengaturan where id = 1 $$;

create or replace function public.hk__lokal() returns timestamp
language sql stable set search_path = public as
$$ select now() at time zone (select zona_waktu from hk_pengaturan where id = 1) $$;

create or replace function public.hk__fmt_jam(t timestamptz) returns text
language sql stable set search_path = public as
$$ select case when t is null then null
          else to_char(t at time zone (select zona_waktu from hk_pengaturan where id = 1), 'HH24:MI') end $$;

create or replace function public.hk__jam_pulang(p_tgl date) returns time
language sql stable set search_path = public as
$$ select case when extract(isodow from p_tgl) = 5 and jam_pulang_jumat is not null
               then jam_pulang_jumat else jam_pulang_min end
   from hk_pengaturan where id = 1 $$;

-- Hari efektif = hari sekolah & bukan hari libur
create or replace function public.hk__hari_efektif(p_dari date, p_sampai date) returns setof date
language sql stable set search_path = public as $$
  select g::date
  from generate_series(p_dari, p_sampai, interval '1 day') g
  where extract(isodow from g)::int = any (coalesce((select hari_sekolah from hk_pengaturan where id = 1), '{}'::int[]))
    and not exists (select 1 from hk_hari_libur h where h.tanggal = g::date)
$$;

-- Tanggal terakhir yang sudah boleh dihitung "alpa":
-- hari ini bila absen masuk sudah ditutup, selain itu kemarin.
create or replace function public.hk__batas_alpa() returns date
language sql stable set search_path = public as $$
  select case when (hk__lokal())::time >= c.jam_tutup_masuk
              then (hk__lokal())::date else (hk__lokal())::date - 1 end
  from hk_pengaturan c where c.id = 1
$$;

-- Alpa tidak dihitung sebelum tanggal mulai aplikasi / sebelum akun siswa dibuat
create or replace function public.hk__mulai(p_siswa bigint) returns date
language sql stable set search_path = public as $$
  select greatest(c.tanggal_mulai, (p.dibuat at time zone c.zona_waktu)::date)
  from hk_pengguna p, hk_pengaturan c
  where p.id = p_siswa and c.id = 1
$$;

create or replace function public.hk__jarak_m(lat1 double precision, lng1 double precision,
                                              lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

create or replace function public.hk__qr_sig(p_jenis text, p_slot bigint) returns text
language sql stable security definer set search_path = public, extensions as $$
  select substr(encode(hmac(p_jenis || ':' || p_slot::text, qr_rahasia, 'sha256'), 'hex'), 1, 24)
  from hk_pengaturan where id = 1
$$;

create or replace function public.hk__user(p_token text) returns public.hk_pengguna
language plpgsql stable security definer set search_path = public, extensions as $$
declare u hk_pengguna;
begin
  select p.* into u
  from hk_sesi s join hk_pengguna p on p.id = s.pengguna_id
  where s.token_hash = hk__hash(coalesce(p_token, ''))
    and s.kadaluarsa > now() and p.aktif;
  if u.id is null then
    raise exception 'SESI_BERAKHIR: Sesi berakhir, silakan masuk kembali.';
  end if;
  return u;
end $$;

create or replace function public.hk__wajib(u public.hk_pengguna, variadic p_peran text[]) returns void
language plpgsql as $$
begin
  if not (u.peran = any (p_peran)) then
    raise exception 'Akses ditolak: fitur ini tidak tersedia untuk peran %.', u.peran;
  end if;
end $$;

create or replace function public.hk__boleh_kelas(u public.hk_pengguna, p_kelas bigint) returns boolean
language plpgsql stable set search_path = public as $$
begin
  if u.peran in ('admin','kepala','bk') then return true; end if;
  if u.peran = 'wali' then
    return exists (select 1 from hk_kelas k where k.id = p_kelas and k.wali_id = u.id);
  end if;
  return false;
end $$;

create or replace function public.hk__profil(u public.hk_pengguna) returns json
language plpgsql stable set search_path = public as $$
begin
  return json_build_object(
    'id', u.id, 'username', u.username, 'nama', u.nama, 'peran', u.peran,
    'kelas_id', u.kelas_id,
    'kelas', (select nama from hk_kelas where id = u.kelas_id),
    'harus_ganti_password', u.harus_ganti_password,
    'foto_versi', (select floor(extract(epoch from f.diubah))::bigint from hk_foto f where f.pengguna_id = u.id),
    'foto_terverifikasi', coalesce((select f.terverifikasi from hk_foto f where f.pengguna_id = u.id), false),
    'kelas_wali', (select coalesce(json_agg(json_build_object('id', k.id, 'nama', k.nama) order by k.nama), '[]'::json)
                   from hk_kelas k where k.wali_id = u.id));
end $$;

create or replace function public.hk__rekap(p_siswa bigint, p_dari date, p_sampai date) returns json
language plpgsql stable security definer set search_path = public as $$
declare v_mulai date; v_batas date; r json;
begin
  v_mulai := greatest(p_dari, hk__mulai(p_siswa));
  v_batas := least(p_sampai, hk__batas_alpa());
  select json_build_object(
    'hadir',     count(*) filter (where a.status = 'hadir'),
    'terlambat', count(*) filter (where a.status = 'terlambat'),
    'izin',      count(*) filter (where a.status = 'izin'),
    'sakit',     count(*) filter (where a.status = 'sakit'),
    'alpa',      count(*) filter (where a.status = 'alpa')
                 + (select count(*) from hk__hari_efektif(v_mulai, v_batas) as h(tgl)
                    where not exists (select 1 from hk_absensi x
                                      where x.siswa_id = p_siswa and x.tanggal = h.tgl)),
    -- hari efektif yang sudah "berjalan": sampai batas alpa, ditambah hari ini bila sudah ada catatan
    'hari_efektif', (select count(*) from hk__hari_efektif(v_mulai, least(p_sampai, hk__lokal()::date)) as h(tgl)
                     where h.tgl <= v_batas
                        or exists (select 1 from hk_absensi x where x.siswa_id = p_siswa and x.tanggal = h.tgl)))
  into r
  from hk_absensi a
  where a.siswa_id = p_siswa and a.tanggal between v_mulai and p_sampai;
  return r;
end $$;

create or replace function public.hk__riwayat(p_siswa bigint, p_tahun int, p_bulan int) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  c hk_pengaturan := hk__cfg();
  v_awal date; v_akhir date; v_hari_ini date := hk__lokal()::date;
  v_mulai date := hk__mulai(p_siswa); v_batas date := hk__batas_alpa();
begin
  if p_bulan not between 1 and 12 then raise exception 'Bulan tidak valid.'; end if;
  v_awal  := make_date(p_tahun, p_bulan, 1);
  v_akhir := (v_awal + interval '1 month' - interval '1 day')::date;
  return json_build_object(
    'tahun', p_tahun, 'bulan', p_bulan, 'hari_ini', v_hari_ini,
    'rekap', hk__rekap(p_siswa, v_awal, v_akhir),
    'hari', coalesce((
      select json_agg(x order by x.tanggal desc) from (
        select g::date as tanggal,
               (extract(isodow from g)::int = any (c.hari_sekolah)) as hari_sekolah,
               l.keterangan as libur,
               coalesce(a.status,
                 case when extract(isodow from g)::int = any (c.hari_sekolah) and l.tanggal is null
                           and g::date >= v_mulai
                      then case when g::date <= v_batas then 'alpa'
                                when g::date = v_hari_ini then 'belum' end
                 end) as status,
               hk__fmt_jam(a.jam_masuk)  as jam_masuk,
               hk__fmt_jam(a.jam_pulang) as jam_pulang,
               a.menit_terlambat, a.keterangan, a.sumber
        from generate_series(v_awal, least(v_akhir, v_hari_ini), interval '1 day') g
        left join hk_hari_libur l on l.tanggal = g::date
        left join hk_absensi a on a.siswa_id = p_siswa and a.tanggal = g::date
      ) x), '[]'::json));
end $$;

-- ---------- Fase 2: bantuan notifikasi & peringatan ----------

-- Normalisasi nomor WA ke format 62xxxxxxxxxx (null bila tidak valid)
create or replace function public.hk__norm_hp(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
begin
  if d like '0%' then d := '62' || substr(d, 2);
  elsif d like '8%' then d := '62' || d; end if;
  if d !~ '^62[0-9]{8,13}$' then return null; end if;
  return d;
end $$;

-- Masukkan pesan ke antrean (sekali per siswa/tanggal/jenis/ref)
create or replace function public.hk__notif(p_siswa bigint, p_jenis text, p_tanggal date, p_ref bigint, p_pesan text) returns void
language plpgsql security definer set search_path = public as $$
declare v_no text;
begin
  select hk__norm_hp(no_wa_ortu) into v_no from hk_pengguna where id = p_siswa;
  if v_no is null then return; end if;
  insert into hk_notifikasi (siswa_id, tanggal, jenis, ref, tujuan, pesan)
  values (p_siswa, p_tanggal, p_jenis, coalesce(p_ref, 0), v_no, p_pesan)
  on conflict (siswa_id, tanggal, jenis, ref) do nothing;
end $$;

-- Kirim antrean lewat Fonnte (pg_net, asinkron). Tanpa gateway: pesan tetap "antri"
-- dan bisa dikirim manual dari menu Notifikasi.
create or replace function public.hk__kirim_antrean(p_batas int default 15) returns int
language plpgsql security definer set search_path = public as $$
declare c hk_pengaturan := hk__cfg(); n record; v_req bigint; v_jml int := 0;
begin
  if not c.wa_aktif or coalesce(c.wa_token, '') = '' then return 0; end if;
  if to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is null then return 0; end if;
  for n in select * from hk_notifikasi where status = 'antri' order by id limit p_batas for update skip locked loop
    execute 'select net.http_get($1, $2, ''{}''::jsonb, 10000)'
      into v_req
      using 'https://api.fonnte.com/send/',
            jsonb_build_object('token', c.wa_token, 'target', n.tujuan, 'message', n.pesan, 'countryCode', '62');
    update hk_notifikasi set status = 'diproses', req_id = v_req, diubah = now() where id = n.id;
    v_jml := v_jml + 1;
  end loop;
  return v_jml;
end $$;

-- Baca hasil pengiriman dari pg_net
create or replace function public.hk__perbarui_status() returns void
language plpgsql security definer set search_path = public as $$
begin
  if to_regclass('net._http_response') is null then return; end if;
  execute $q$
    update hk_notifikasi n
       set status = case when r.status_code = 200 and coalesce(r.content, '') ~ '"status"\s*:\s*true' then 'terkirim' else 'gagal' end,
           alasan = case when r.status_code = 200 and coalesce(r.content, '') ~ '"status"\s*:\s*true' then null
                         else left(coalesce(r.error_msg, r.content, 'HTTP ' || r.status_code), 200) end,
           diubah = now()
      from net._http_response r
     where n.status = 'diproses' and r.id = n.req_id
  $q$;
  -- respons pg_net hanya disimpan beberapa jam; yang terlalu lama dianggap gagal
  update hk_notifikasi set status = 'gagal', alasan = 'Tidak ada respons dari gateway', diubah = now()
   where status = 'diproses' and diubah < now() - interval '3 hours';
end $$;

-- Jumlah hari efektif alpa berturut-turut sampai batas alpa
create or replace function public.hk__alpa_beruntun(p_siswa bigint) returns int
language sql stable set search_path = public as $$
  with h as (
    select h.tgl, row_number() over (order by h.tgl desc) rn
    from hk__hari_efektif(greatest(hk__mulai(p_siswa), hk__batas_alpa() - 60), hk__batas_alpa()) as h(tgl)
  ), x as (
    select h.rn, (a.id is null or a.status = 'alpa') as alpa
    from h left join hk_absensi a on a.siswa_id = p_siswa and a.tanggal = h.tgl
  )
  select coalesce((select min(rn) from x where not alpa) - 1, (select count(*) from x))::int
$$;

-- Cek tugas berkala: notifikasi alpa setelah absen masuk ditutup + kirim antrean.
-- Dijalankan pg_cron tiap menit (lihat bagian 9), atau manual oleh admin.
create or replace function public.hk__cron() returns json
language plpgsql security definer set search_path = public as $$
declare c hk_pengaturan := hk__cfg(); v_lokal timestamp := hk__lokal(); v_tgl date; v_alpa int := 0; v_kirim int;
begin
  v_tgl := v_lokal::date;
  perform hk__perbarui_status();
  if c.notif_alpa and v_lokal::time >= c.jam_tutup_masuk
     and exists (select 1 from hk__hari_efektif(v_tgl, v_tgl)) then
    with calon as (
      select s.id, s.nama, k.nama as kelas
      from hk_pengguna s left join hk_kelas k on k.id = s.kelas_id
      where s.peran = 'siswa' and s.aktif and hk__norm_hp(s.no_wa_ortu) is not null
        and hk__mulai(s.id) <= v_tgl
        and not exists (select 1 from hk_absensi a where a.siswa_id = s.id and a.tanggal = v_tgl and a.status <> 'alpa')
        and not exists (select 1 from hk_notifikasi n where n.siswa_id = s.id and n.tanggal = v_tgl and n.jenis = 'alpa')
    )
    select count(*) into v_alpa from calon,
      lateral (select hk__notif(calon.id, 'alpa', v_tgl, 0,
        format('Assalamu''alaikum, Bapak/Ibu. Hingga pukul %s %s hari ini, Ananda %s (%s) belum tercatat hadir di %s dan belum ada keterangan izin/sakit. Jika Ananda berhalangan, mohon kabari wali kelas. Semoga Ananda dalam keadaan baik. — HadirKuy',
               to_char(c.jam_tutup_masuk, 'HH24:MI'), c.label_zona, calon.nama, coalesce(calon.kelas, '-'), c.nama_madrasah))) t;
  end if;
  v_kirim := hk__kirim_antrean(30);
  return json_build_object('alpa_diantrekan', v_alpa, 'dikirim', v_kirim);
end $$;

-- =====================================================================
-- 3. RPC AKUN
-- =====================================================================

create or replace function public.hk_masuk(p_username text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna; v_token text; v_gagal int;
begin
  select * into u from hk_pengguna where lower(username) = lower(trim(coalesce(p_username, '')));
  if u.id is null then
    perform pg_sleep(0.4);
    return json_build_object('ok', false, 'pesan', 'NISN/username atau kata sandi salah.');
  end if;
  if not u.aktif then
    return json_build_object('ok', false, 'pesan', 'Akun ini dinonaktifkan. Hubungi admin madrasah.');
  end if;
  if u.kunci_sampai is not null and u.kunci_sampai > now() then
    return json_build_object('ok', false, 'pesan',
      format('Terlalu banyak percobaan gagal. Coba lagi setelah pukul %s.', hk__fmt_jam(u.kunci_sampai)));
  end if;
  if u.password_hash <> crypt(coalesce(p_password, ''), u.password_hash) then
    v_gagal := case when u.kunci_sampai is not null then 1 else u.gagal_login + 1 end;
    update hk_pengguna
       set gagal_login  = v_gagal,
           kunci_sampai = case when v_gagal >= 5 then now() + interval '10 minutes' else null end
     where id = u.id;
    return json_build_object('ok', false, 'pesan',
      case when v_gagal >= 5 then 'Terlalu banyak percobaan gagal. Akun dikunci 10 menit.'
           else 'NISN/username atau kata sandi salah.' end);
  end if;

  update hk_pengguna set gagal_login = 0, kunci_sampai = null where id = u.id;
  delete from hk_sesi where kadaluarsa < now();
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into hk_sesi (token_hash, pengguna_id, kadaluarsa)
  values (hk__hash(v_token), u.id, now() + interval '30 days');
  return json_build_object('ok', true, 'token', v_token, 'profil', hk__profil(u));
end $$;

create or replace function public.hk_keluar(p_token text) returns void
language sql security definer set search_path = public, extensions as
$$ delete from hk_sesi where token_hash = hk__hash(coalesce(p_token, '')) $$;

create or replace function public.hk_ganti_password(p_token text, p_lama text, p_baru text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  if u.password_hash <> crypt(coalesce(p_lama, ''), u.password_hash) then
    raise exception 'Kata sandi lama salah.';
  end if;
  if length(coalesce(p_baru, '')) < 6 then
    raise exception 'Kata sandi baru minimal 6 karakter.';
  end if;
  if lower(p_baru) = lower(u.username) then
    raise exception 'Kata sandi baru tidak boleh sama dengan NISN/username.';
  end if;
  update hk_pengguna
     set password_hash = crypt(p_baru, gen_salt('bf', 8)), harus_ganti_password = false
   where id = u.id;
  -- keluarkan sesi di perangkat lain
  delete from hk_sesi where pengguna_id = u.id and token_hash <> hk__hash(p_token);
  select * into u from hk_pengguna where id = u.id;
  return hk__profil(u);
end $$;

-- =====================================================================
-- 4. RPC SISWA
-- =====================================================================

create or replace function public.hk_beranda(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token);
  c hk_pengaturan := hk__cfg();
  v_tgl date := hk__lokal()::date;
  v_libur text; v_sekolah boolean; v_awal date; r hk_absensi;
begin
  select keterangan into v_libur from hk_hari_libur where tanggal = v_tgl;
  v_sekolah := extract(isodow from v_tgl)::int = any (c.hari_sekolah) and v_libur is null;
  v_awal := date_trunc('month', v_tgl)::date;
  if u.peran = 'siswa' then
    select * into r from hk_absensi where siswa_id = u.id and tanggal = v_tgl;
  end if;
  return json_build_object(
    'profil', hk__profil(u),
    'madrasah', c.nama_madrasah, 'zona_waktu', c.zona_waktu, 'label_zona', c.label_zona,
    'waktu_server', floor(extract(epoch from now()) * 1000)::bigint,
    'wajib_lokasi', c.wajib_lokasi, 'radius_m', c.radius_m,
    'hari_ini', json_build_object(
        'tanggal', v_tgl, 'hari_sekolah', v_sekolah, 'libur', v_libur,
        'jam_buka_masuk',  to_char(c.jam_buka_masuk, 'HH24:MI'),
        'jam_masuk',       to_char(c.jam_masuk, 'HH24:MI'),
        'toleransi_menit', c.toleransi_menit,
        'jam_tutup_masuk', to_char(c.jam_tutup_masuk, 'HH24:MI'),
        'jam_pulang',      to_char(hk__jam_pulang(v_tgl), 'HH24:MI'),
        'jam_tutup_pulang',to_char(c.jam_tutup_pulang, 'HH24:MI')),
    'absen', case when r.id is null then null else json_build_object(
        'status', r.status, 'jam_masuk', hk__fmt_jam(r.jam_masuk),
        'jam_pulang', hk__fmt_jam(r.jam_pulang), 'menit_terlambat', r.menit_terlambat,
        'keterangan', r.keterangan, 'sumber', r.sumber,
        'perasaan', r.perasaan, 'ingin_cerita', r.ingin_cerita) end,
    'rekap_bulan', case when u.peran = 'siswa'
        then hk__rekap(u.id, v_awal, (v_awal + interval '1 month' - interval '1 day')::date) end,
    -- Fase 2
    'kunci_perangkat', c.kunci_perangkat,
    'pengajuan_menunggu', case
        when u.peran = 'siswa' then (select count(*) from hk_pengajuan p where p.siswa_id = u.id and p.status = 'menunggu')
        when u.peran in ('admin', 'kepala', 'bk', 'wali') then (
          select count(*) from hk_pengajuan p join hk_pengguna s on s.id = p.siswa_id
          where p.status = 'menunggu' and (u.peran <> 'wali' or hk__boleh_kelas(u, s.kelas_id)))
        else 0 end);
end $$;

create or replace function public.hk_riwayat_saya(p_token text, p_tahun int, p_bulan int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'siswa');
  return hk__riwayat(u.id, p_tahun, p_bulan);
end $$;

-- Inti pencatatan absen (dipakai scan QR siswa, scan kartu petugas, dan sinkron offline).
-- p_waktu = saat kejadian (sekarang, atau waktu QR/scan saat offline).
create or replace function public.hk__catat_absen(u public.hk_pengguna, p_jenis text, p_waktu timestamptz,
                                                  p_dalam boolean, p_hp text, p_sumber text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  c hk_pengaturan := hk__cfg();
  v_lokal timestamp := p_waktu at time zone c.zona_waktu;
  v_tgl date := (p_waktu at time zone c.zona_waktu)::date;
  v_jam time := (p_waktu at time zone c.zona_waktu)::time;
  v_libur text; r hk_absensi; v_status text; v_menit int := 0; v_batas_pulang time;
  v_kelas text := coalesce((select nama from hk_kelas where id = u.kelas_id), '-');
  v_baru boolean := p_waktu > now() - interval '30 minutes';   -- notifikasi hanya untuk kejadian baru
begin
  select keterangan into v_libur from hk_hari_libur where tanggal = v_tgl;
  if v_libur is not null then
    raise exception 'Hari itu libur: %.', v_libur;
  end if;
  if not (extract(isodow from v_tgl)::int = any (c.hari_sekolah)) then
    raise exception 'Hari itu bukan hari sekolah.';
  end if;

  select * into r from hk_absensi where siswa_id = u.id and tanggal = v_tgl;

  if p_jenis = 'masuk' then
    if v_jam < c.jam_buka_masuk then
      raise exception 'Absen masuk baru dibuka pukul % %.', to_char(c.jam_buka_masuk, 'HH24:MI'), c.label_zona;
    end if;
    if v_jam > c.jam_tutup_masuk then
      raise exception 'Absen masuk sudah ditutup pukul % %. Silakan temui wali kelas.',
        to_char(c.jam_tutup_masuk, 'HH24:MI'), c.label_zona;
    end if;
    if r.id is not null then
      if r.jam_masuk is not null then
        raise exception '% sudah absen masuk pukul % %.', case when p_sumber = 'qr' then 'Kamu' else u.nama end,
          hk__fmt_jam(r.jam_masuk), c.label_zona;
      end if;
      if r.status in ('hadir', 'terlambat') then
        raise exception 'Kehadiran hari itu sudah dicatat wali kelas sebagai "%".', r.status;
      end if;
    end if;
    if v_jam > c.jam_masuk + make_interval(mins => c.toleransi_menit) then
      v_status := 'terlambat';
      v_menit  := ceil(extract(epoch from (v_jam - c.jam_masuk)) / 60.0)::int;
    else
      v_status := 'hadir';
    end if;
    insert into hk_absensi (siswa_id, tanggal, jam_masuk, status, menit_terlambat, dalam_radius_masuk, sumber, perangkat_hash)
    values (u.id, v_tgl, p_waktu, v_status, v_menit, p_dalam, p_sumber, p_hp)
    on conflict (siswa_id, tanggal) do update
      set jam_masuk = excluded.jam_masuk, status = excluded.status,
          menit_terlambat = excluded.menit_terlambat, dalam_radius_masuk = excluded.dalam_radius_masuk,
          perangkat_hash = excluded.perangkat_hash, keterangan = null, pengajuan_id = null,
          sumber = excluded.sumber, diubah = now();

    if v_baru and ((v_status = 'hadir' and c.notif_masuk) or (v_status = 'terlambat' and c.notif_terlambat)) then
      perform hk__notif(u.id, v_status, v_tgl, 0, case when v_status = 'hadir'
        then format('Assalamu''alaikum, Bapak/Ibu. Ananda %s (%s) telah tiba di %s pukul %s %s. Terima kasih atas dukungannya. — HadirKuy',
                    u.nama, v_kelas, c.nama_madrasah, to_char(v_jam, 'HH24:MI'), c.label_zona)
        else format('Assalamu''alaikum, Bapak/Ibu. Ananda %s (%s) tiba di %s pukul %s %s, terlambat %s menit. Mohon dukungannya agar Ananda dapat berangkat lebih awal. Jazakumullah khairan. — HadirKuy',
                    u.nama, v_kelas, c.nama_madrasah, to_char(v_jam, 'HH24:MI'), c.label_zona, v_menit) end);
      begin perform hk__kirim_antrean(5); exception when others then null; end;
    end if;
    return json_build_object('jenis', 'masuk', 'status', v_status, 'jam', to_char(v_jam, 'HH24:MI'), 'tanggal', v_tgl,
                             'menit_terlambat', v_menit, 'label_zona', c.label_zona,
                             'siswa', json_build_object('id', u.id, 'nama', u.nama, 'nisn', u.username, 'kelas', v_kelas));
  end if;

  -- PULANG
  if r.id is null or r.jam_masuk is null then
    raise exception 'Belum ada absen masuk % hari itu. Temui wali kelas agar kehadiran dicatat.',
      case when p_sumber = 'qr' then '' else 'untuk ' || u.nama end;
  end if;
  if r.jam_pulang is not null then
    raise exception '% sudah absen pulang pukul % %.', case when p_sumber = 'qr' then 'Kamu' else u.nama end,
      hk__fmt_jam(r.jam_pulang), c.label_zona;
  end if;
  v_batas_pulang := hk__jam_pulang(v_tgl);
  if v_jam < v_batas_pulang then
    raise exception 'Absen pulang dibuka pukul % %. Jika perlu pulang lebih awal, mintalah izin wali kelas.',
      to_char(v_batas_pulang, 'HH24:MI'), c.label_zona;
  end if;
  if v_jam > c.jam_tutup_pulang then
    raise exception 'Absen pulang sudah ditutup pukul % %.', to_char(c.jam_tutup_pulang, 'HH24:MI'), c.label_zona;
  end if;
  update hk_absensi set jam_pulang = p_waktu, dalam_radius_pulang = p_dalam, diubah = now() where id = r.id;
  if v_baru and c.notif_pulang then
    perform hk__notif(u.id, 'pulang', v_tgl, 0,
      format('Assalamu''alaikum, Bapak/Ibu. Ananda %s telah absen pulang dari %s pukul %s %s. Semoga selamat sampai di rumah. — HadirKuy',
             u.nama, c.nama_madrasah, to_char(v_jam, 'HH24:MI'), c.label_zona));
    begin perform hk__kirim_antrean(5); exception when others then null; end;
  end if;
  return json_build_object('jenis', 'pulang', 'status', r.status, 'jam', to_char(v_jam, 'HH24:MI'), 'tanggal', v_tgl,
                           'menit_terlambat', r.menit_terlambat, 'label_zona', c.label_zona,
                           'siswa', json_build_object('id', u.id, 'nama', u.nama, 'nisn', u.username, 'kelas', v_kelas));
end $$;

-- Absen siswa dengan memindai QR layar. p_tertunda = dikirim belakangan dari antrean offline:
-- waktu absen diambil dari QR itu sendiri (kapan QR tampil di layar), bukan jam HP.
drop function if exists public.hk_absen(text, text, double precision, double precision);
drop function if exists public.hk_absen(text, text, double precision, double precision, text);
create or replace function public.hk_absen(p_token text, p_qr text,
                                           p_lat double precision default null,
                                           p_lng double precision default null,
                                           p_perangkat text default null,
                                           p_tertunda boolean default false) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token);
  c hk_pengaturan := hk__cfg();
  v_bagian text[]; v_jenis text; v_slot bigint; v_slot_kini bigint; v_waktu timestamptz;
  v_jarak double precision; v_dalam boolean; v_hp text; v_lain text; v_tgl date;
begin
  if u.peran <> 'siswa' then
    raise exception 'Hanya akun siswa yang dapat melakukan absen.';
  end if;

  -- 1) Validasi QR
  v_bagian := string_to_array(coalesce(p_qr, ''), '|');
  if coalesce(array_length(v_bagian, 1), 0) <> 4
     or v_bagian[1] <> 'HADIRKUY'
     or v_bagian[2] not in ('masuk', 'pulang')
     or v_bagian[3] !~ '^[0-9]{1,12}$' then
    raise exception 'QR Code tidak dikenali. Pindai QR HadirKuy yang tampil di layar madrasah.';
  end if;
  v_jenis := v_bagian[2];
  v_slot  := v_bagian[3]::bigint;
  v_slot_kini := floor(extract(epoch from now()) / c.qr_interval_detik)::bigint;
  if v_bagian[4] <> hk__qr_sig(v_jenis, v_slot) then
    raise exception 'QR Code tidak valid.';
  end if;
  if coalesce(p_tertunda, false) then
    if v_slot > v_slot_kini or v_slot < v_slot_kini - (86400 / c.qr_interval_detik) then
      raise exception 'Data absen offline sudah lebih dari 24 jam. Temui wali kelas agar kehadiranmu dicatat.';
    end if;
    v_waktu := to_timestamp(v_slot * c.qr_interval_detik);
  else
    if v_slot not in (v_slot_kini, v_slot_kini - 1) then
      raise exception 'QR Code sudah kedaluwarsa. Pindai QR yang sedang tampil di layar.';
    end if;
    v_waktu := now();
  end if;
  v_tgl := (v_waktu at time zone c.zona_waktu)::date;

  -- 2) Kunci perangkat: satu akun = satu HP, satu HP = satu siswa per hari
  if c.kunci_perangkat then
    if coalesce(length(p_perangkat), 0) < 16 then
      raise exception 'Perangkat tidak dikenali. Muat ulang aplikasi lalu coba lagi.';
    end if;
    v_hp := hk__hash('hk-perangkat:' || p_perangkat);
    if u.perangkat_hash is not null and u.perangkat_hash <> v_hp then
      raise exception 'Akunmu terdaftar di HP lain. Absen hanya bisa dari HP milikmu. Jika HP-mu berganti atau hilang, minta wali kelas mereset perangkat.';
    end if;
    select s.nama into v_lain
    from hk_absensi a join hk_pengguna s on s.id = a.siswa_id
    where a.tanggal = v_tgl and a.perangkat_hash = v_hp and a.siswa_id <> u.id
    limit 1;
    if v_lain is not null then
      raise exception 'HP ini sudah dipakai absen oleh akun lain hari ini. Jika berbagi HP dengan saudara, minta wali kelas mencatat kehadiranmu atau gunakan Kartu QR di pos petugas.';
    end if;
    if u.perangkat_hash is null then
      update hk_pengguna set perangkat_hash = v_hp, perangkat_terikat = now() where id = u.id;
    end if;
  end if;

  -- 3) Lokasi (hanya status dalam/luar radius yang disimpan)
  if p_lat is not null and p_lng is not null and c.lat is not null and c.lng is not null then
    v_jarak := hk__jarak_m(p_lat, p_lng, c.lat, c.lng);
    v_dalam := v_jarak <= c.radius_m;
  end if;
  if c.wajib_lokasi then
    if c.lat is null or c.lng is null then
      raise exception 'Lokasi madrasah belum diatur. Hubungi admin madrasah.';
    end if;
    if p_lat is null or p_lng is null then
      raise exception 'Lokasi tidak terbaca. Aktifkan GPS dan izinkan akses lokasi, lalu coba lagi.';
    end if;
    if not v_dalam then
      raise exception 'Kamu terdeteksi sekitar % m dari madrasah (batas % m). Absen hanya bisa dilakukan di area madrasah.',
        round(v_jarak)::int, c.radius_m;
    end if;
  end if;

  return hk__catat_absen(u, v_jenis, v_waktu, v_dalam, v_hp, 'qr');
end $$;

-- =====================================================================
-- 5. RPC LAYAR QR (admin / petugas)
-- =====================================================================

create or replace function public.hk_qr_ambil(p_token text, p_jenis text default 'otomatis') returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token);
  c hk_pengaturan := hk__cfg();
  v_epoch numeric := extract(epoch from now());
  v_slot bigint; v_jenis text; v_lokal timestamp := hk__lokal();
begin
  perform hk__wajib(u, 'admin', 'petugas');
  if p_jenis not in ('masuk', 'pulang', 'otomatis') then raise exception 'Jenis QR tidak valid.'; end if;
  v_jenis := case when p_jenis <> 'otomatis' then p_jenis
                  when v_lokal::time >= hk__jam_pulang(v_lokal::date) then 'pulang'
                  else 'masuk' end;
  v_slot := floor(v_epoch / c.qr_interval_detik)::bigint;
  return json_build_object(
    'isi', 'HADIRKUY|' || v_jenis || '|' || v_slot || '|' || hk__qr_sig(v_jenis, v_slot),
    'jenis', v_jenis,
    'interval', c.qr_interval_detik,
    'sisa_detik', round(c.qr_interval_detik - (v_epoch - v_slot * c.qr_interval_detik), 2),
    'waktu_server', floor(v_epoch * 1000)::bigint,
    'madrasah', c.nama_madrasah, 'zona_waktu', c.zona_waktu, 'label_zona', c.label_zona,
    'sudah_masuk',  (select count(*) from hk_absensi where tanggal = v_lokal::date and jam_masuk is not null),
    'sudah_pulang', (select count(*) from hk_absensi where tanggal = v_lokal::date and jam_pulang is not null));
end $$;

-- =====================================================================
-- 6. RPC STAF (wali kelas, BK, kepala, admin)
-- =====================================================================

create or replace function public.hk_kelas_daftar(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  return coalesce((
    select json_agg(x order by x.nama) from (
      select k.id, k.nama, k.wali_id, w.nama as wali_nama,
             (select count(*) from hk_pengguna s where s.kelas_id = k.id and s.peran = 'siswa' and s.aktif) as jumlah_siswa
      from hk_kelas k left join hk_pengguna w on w.id = k.wali_id
      where u.peran <> 'wali' or k.wali_id = u.id) x), '[]'::json);
end $$;

create or replace function public.hk_rekap_harian(p_token text, p_tanggal date default null,
                                                  p_kelas_id bigint default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token);
  c hk_pengaturan := hk__cfg();
  v_hari_ini date := hk__lokal()::date;
  v_tgl date := coalesce(p_tanggal, hk__lokal()::date);
  v_libur text; v_efektif boolean; v_batas date := hk__batas_alpa();
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  if p_kelas_id is null and u.peran = 'wali' then raise exception 'Pilih kelas terlebih dahulu.'; end if;
  if p_kelas_id is not null and not hk__boleh_kelas(u, p_kelas_id) then
    raise exception 'Anda tidak memiliki akses ke kelas ini.';
  end if;
  if v_tgl > v_hari_ini then raise exception 'Tanggal tersebut belum terjadi.'; end if;
  select keterangan into v_libur from hk_hari_libur where tanggal = v_tgl;
  v_efektif := extract(isodow from v_tgl)::int = any (c.hari_sekolah) and v_libur is null;
  return json_build_object(
    'tanggal', v_tgl, 'efektif', v_efektif, 'libur', v_libur,
    'siswa', coalesce((
      select json_agg(x order by x.kelas, x.nama) from (
        select s.id, s.username as nisn, s.nama, s.kelas_id, k.nama as kelas,
               coalesce(a.status,
                 case when v_efektif and v_tgl >= hk__mulai(s.id)
                      then case when v_tgl <= v_batas then 'alpa' else 'belum' end end) as status,
               hk__fmt_jam(a.jam_masuk) as jam_masuk, hk__fmt_jam(a.jam_pulang) as jam_pulang,
               a.menit_terlambat, a.keterangan, a.sumber,
               -- perasaan bersifat pribadi: hanya wali kelas, BK, dan admin
               case when u.peran in ('wali', 'bk', 'admin') then a.perasaan end as perasaan,
               case when u.peran in ('wali', 'bk', 'admin') then a.ingin_cerita end as ingin_cerita,
               (s.perangkat_hash is not null) as perangkat_terikat
        from hk_pengguna s
        left join hk_kelas k on k.id = s.kelas_id
        left join hk_absensi a on a.siswa_id = s.id and a.tanggal = v_tgl
        where s.peran = 'siswa' and s.aktif and (p_kelas_id is null or s.kelas_id = p_kelas_id)
      ) x), '[]'::json));
end $$;

create or replace function public.hk_rekap_bulanan(p_token text, p_kelas_id bigint, p_tahun int, p_bulan int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_awal date; v_akhir date;
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  if p_kelas_id is null or not hk__boleh_kelas(u, p_kelas_id) then
    raise exception 'Anda tidak memiliki akses ke kelas ini.';
  end if;
  v_awal  := make_date(p_tahun, p_bulan, 1);
  v_akhir := (v_awal + interval '1 month' - interval '1 day')::date;
  return json_build_object(
    'kelas', (select nama from hk_kelas where id = p_kelas_id),
    'tahun', p_tahun, 'bulan', p_bulan,
    'siswa', coalesce((
      select json_agg(json_build_object('id', s.id, 'nisn', s.username, 'nama', s.nama,
                                        'rekap', hk__rekap(s.id, v_awal, v_akhir)) order by s.nama)
      from hk_pengguna s
      where s.peran = 'siswa' and s.aktif and s.kelas_id = p_kelas_id), '[]'::json));
end $$;

create or replace function public.hk_riwayat_siswa(p_token text, p_siswa bigint, p_tahun int, p_bulan int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); s hk_pengguna;
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  select * into s from hk_pengguna where id = p_siswa and peran = 'siswa';
  if s.id is null then raise exception 'Siswa tidak ditemukan.'; end if;
  if not hk__boleh_kelas(u, s.kelas_id) then raise exception 'Anda tidak memiliki akses ke siswa ini.'; end if;
  return hk__riwayat(s.id, p_tahun, p_bulan);
end $$;

-- Koreksi manual oleh admin / wali kelas (izin, sakit, lupa absen, dll.)
create or replace function public.hk_absen_manual(p_token text, p_siswa bigint, p_tanggal date,
                                                  p_status text, p_keterangan text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); s hk_pengguna; v_hari_ini date := hk__lokal()::date;
begin
  perform hk__wajib(u, 'admin', 'wali');
  select * into s from hk_pengguna where id = p_siswa and peran = 'siswa';
  if s.id is null then raise exception 'Siswa tidak ditemukan.'; end if;
  if u.peran = 'wali' and not hk__boleh_kelas(u, s.kelas_id) then
    raise exception 'Anda hanya dapat mengubah absensi siswa di kelas perwalian Anda.';
  end if;
  if p_tanggal is null then raise exception 'Tanggal wajib diisi.'; end if;
  if p_status = 'reset' then
    delete from hk_absensi where siswa_id = s.id and tanggal = p_tanggal;
    return;
  end if;
  if p_status not in ('hadir', 'terlambat', 'izin', 'sakit', 'alpa') then
    raise exception 'Status tidak valid.';
  end if;
  if p_tanggal > v_hari_ini and p_status not in ('izin', 'sakit') then
    raise exception 'Untuk tanggal yang akan datang hanya bisa diisi izin atau sakit.';
  end if;
  if p_tanggal > v_hari_ini + 30 then
    raise exception 'Tanggal terlalu jauh ke depan (maksimal 30 hari).';
  end if;
  insert into hk_absensi (siswa_id, tanggal, status, keterangan, sumber, diubah_oleh, diubah)
  values (s.id, p_tanggal, p_status, nullif(trim(coalesce(p_keterangan, '')), ''), 'manual', u.id, now())
  on conflict (siswa_id, tanggal) do update
    set status = excluded.status,
        keterangan = excluded.keterangan,
        menit_terlambat = case when excluded.status = 'terlambat' then hk_absensi.menit_terlambat else 0 end,
        sumber = 'manual', diubah_oleh = u.id, diubah = now();
end $$;

-- =====================================================================
-- 7. RPC ADMIN
-- =====================================================================

create or replace function public.hk_admin_pengaturan(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg();
begin
  perform hk__wajib(u, 'admin');
  return json_build_object(
    'pengaturan', to_jsonb(c) - 'qr_rahasia' - 'wa_token',
    'wa_token_ada', coalesce(c.wa_token, '') <> '',
    'pg_net_ada', to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is not null,
    'pg_cron_ada', to_regclass('cron.job') is not null,
    'libur', coalesce((select json_agg(l order by l.tanggal) from hk_hari_libur l
                       where l.tanggal >= hk__lokal()::date - 90), '[]'::json));
end $$;

create or replace function public.hk_admin_pengaturan_simpan(p_token text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_zona text; v_hari int[];
begin
  perform hk__wajib(u, 'admin');
  v_zona := coalesce(nullif(p_data->>'zona_waktu', ''), 'Asia/Makassar');
  perform now() at time zone v_zona;  -- gagal bila zona tidak dikenal
  v_hari := array(select (jsonb_array_elements_text(coalesce(p_data->'hari_sekolah', '[]'::jsonb)))::int);
  if coalesce(array_length(v_hari, 1), 0) = 0 then raise exception 'Pilih minimal satu hari sekolah.'; end if;

  update hk_pengaturan set
    nama_madrasah     = coalesce(nullif(trim(p_data->>'nama_madrasah'), ''), nama_madrasah),
    zona_waktu        = v_zona,
    label_zona        = coalesce(nullif(trim(p_data->>'label_zona'), ''), label_zona),
    jam_buka_masuk    = (p_data->>'jam_buka_masuk')::time,
    jam_masuk         = (p_data->>'jam_masuk')::time,
    toleransi_menit   = greatest(0, coalesce((p_data->>'toleransi_menit')::int, 0)),
    jam_tutup_masuk   = (p_data->>'jam_tutup_masuk')::time,
    jam_pulang_min    = (p_data->>'jam_pulang_min')::time,
    jam_pulang_jumat  = nullif(p_data->>'jam_pulang_jumat', '')::time,
    jam_tutup_pulang  = (p_data->>'jam_tutup_pulang')::time,
    hari_sekolah      = v_hari,
    tanggal_mulai     = coalesce(nullif(p_data->>'tanggal_mulai', '')::date, tanggal_mulai),
    wajib_lokasi      = coalesce((p_data->>'wajib_lokasi')::boolean, true),
    lat               = nullif(p_data->>'lat', '')::double precision,
    lng               = nullif(p_data->>'lng', '')::double precision,
    radius_m          = greatest(30, coalesce((p_data->>'radius_m')::int, 150)),
    qr_interval_detik = greatest(15, least(120, coalesce((p_data->>'qr_interval_detik')::int, 30))),
    -- Fase 2
    kunci_perangkat   = coalesce((p_data->>'kunci_perangkat')::boolean, kunci_perangkat),
    wa_aktif          = coalesce((p_data->>'wa_aktif')::boolean, wa_aktif),
    notif_masuk       = coalesce((p_data->>'notif_masuk')::boolean, notif_masuk),
    notif_terlambat   = coalesce((p_data->>'notif_terlambat')::boolean, notif_terlambat),
    notif_pulang      = coalesce((p_data->>'notif_pulang')::boolean, notif_pulang),
    notif_alpa        = coalesce((p_data->>'notif_alpa')::boolean, notif_alpa),
    notif_izin        = coalesce((p_data->>'notif_izin')::boolean, notif_izin)
  where id = 1;

  perform 1 from hk_pengaturan
   where id = 1 and jam_buka_masuk <= jam_masuk and jam_masuk <= jam_tutup_masuk
     and jam_pulang_min < jam_tutup_pulang
     and (jam_pulang_jumat is null or jam_pulang_jumat < jam_tutup_pulang);
  if not found then
    raise exception 'Urutan jam tidak masuk akal. Pastikan: buka masuk ≤ jam masuk ≤ tutup masuk, dan jam pulang < tutup pulang.';
  end if;
  if (select wajib_lokasi and (lat is null or lng is null) from hk_pengaturan where id = 1) then
    raise exception 'Wajib lokasi aktif, tetapi titik lokasi madrasah belum diisi.';
  end if;
end $$;

create or replace function public.hk_admin_libur_simpan(p_token text, p_tanggal date, p_keterangan text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin');
  if p_tanggal is null or coalesce(trim(p_keterangan), '') = '' then
    raise exception 'Tanggal dan keterangan libur wajib diisi.';
  end if;
  insert into hk_hari_libur (tanggal, keterangan) values (p_tanggal, trim(p_keterangan))
  on conflict (tanggal) do update set keterangan = excluded.keterangan;
end $$;

create or replace function public.hk_admin_libur_hapus(p_token text, p_tanggal date) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin');
  delete from hk_hari_libur where tanggal = p_tanggal;
end $$;

create or replace function public.hk_admin_kelas_simpan(p_token text, p_id bigint, p_nama text, p_wali_id bigint) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_id bigint;
begin
  perform hk__wajib(u, 'admin');
  if coalesce(trim(p_nama), '') = '' then raise exception 'Nama kelas wajib diisi.'; end if;
  if exists (select 1 from hk_kelas where lower(nama) = lower(trim(p_nama)) and id is distinct from p_id) then
    raise exception 'Nama kelas "%" sudah ada.', trim(p_nama);
  end if;
  if p_wali_id is not null and not exists (select 1 from hk_pengguna where id = p_wali_id and peran = 'wali') then
    raise exception 'Wali kelas harus pengguna dengan peran "wali".';
  end if;
  if p_id is null then
    insert into hk_kelas (nama, wali_id) values (trim(p_nama), p_wali_id) returning id into v_id;
  else
    update hk_kelas set nama = trim(p_nama), wali_id = p_wali_id where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Kelas tidak ditemukan.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.hk_admin_kelas_hapus(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin');
  delete from hk_kelas where id = p_id;   -- siswa di kelas ini menjadi "tanpa kelas"
end $$;

create or replace function public.hk_admin_pengguna_daftar(p_token text, p_peran text default null,
                                                           p_kelas_id bigint default null,
                                                           p_cari text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin');
  return coalesce((
    select json_agg(x order by x.peran <> 'siswa', x.kelas nulls last, x.nama) from (
      select p.id, p.username, p.nama, p.peran, p.kelas_id, k.nama as kelas,
             p.aktif, p.harus_ganti_password, (p.kunci_sampai > now()) as terkunci,
             p.no_wa_ortu, (p.perangkat_hash is not null) as perangkat_terikat,
             exists (select 1 from hk_foto f where f.pengguna_id = p.id) as ada_foto
      from hk_pengguna p left join hk_kelas k on k.id = p.kelas_id
      where (nullif(p_peran, '') is null or p.peran = p_peran)
        and (p_kelas_id is null or p.kelas_id = p_kelas_id)
        and (nullif(trim(coalesce(p_cari, '')), '') is null
             or p.nama ilike '%' || trim(p_cari) || '%'
             or p.username ilike '%' || trim(p_cari) || '%')
      order by p.nama
      limit 1000) x), '[]'::json);
end $$;

drop function if exists public.hk_admin_pengguna_simpan(text, bigint, text, text, text, bigint, boolean);
create or replace function public.hk_admin_pengguna_simpan(p_token text, p_id bigint, p_username text, p_nama text,
                                                           p_peran text, p_kelas_id bigint, p_aktif boolean,
                                                           p_no_wa_ortu text default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_id bigint; v_user text := trim(coalesce(p_username, ''));
begin
  perform hk__wajib(u, 'admin');
  if v_user = '' or coalesce(trim(p_nama), '') = '' then raise exception 'Username/NISN dan nama wajib diisi.'; end if;
  if v_user !~ '^[A-Za-z0-9._-]{3,40}$' then
    raise exception 'Username/NISN hanya boleh huruf, angka, titik, garis bawah, atau strip (3–40 karakter).';
  end if;
  if p_peran not in ('siswa','wali','bk','kepala','petugas','admin') then raise exception 'Peran tidak valid.'; end if;
  if exists (select 1 from hk_pengguna where lower(username) = lower(v_user) and id is distinct from p_id) then
    raise exception 'Username/NISN "%" sudah dipakai.', v_user;
  end if;
  if nullif(trim(coalesce(p_no_wa_ortu, '')), '') is not null and hk__norm_hp(p_no_wa_ortu) is null then
    raise exception 'Nomor WhatsApp orang tua tidak valid. Contoh: 081234567890.';
  end if;
  if p_id = u.id and (not coalesce(p_aktif, true) or p_peran <> 'admin') then
    raise exception 'Anda tidak dapat menonaktifkan atau menurunkan peran akun Anda sendiri.';
  end if;
  if p_id is null then
    insert into hk_pengguna (username, nama, peran, kelas_id, password_hash, harus_ganti_password, aktif, no_wa_ortu)
    values (v_user, trim(p_nama), p_peran, case when p_peran = 'siswa' then p_kelas_id end,
            crypt(v_user, gen_salt('bf', 8)), true, coalesce(p_aktif, true),
            case when p_peran = 'siswa' then hk__norm_hp(p_no_wa_ortu) end)
    returning id into v_id;
  else
    update hk_pengguna
       set username = v_user, nama = trim(p_nama), peran = p_peran,
           kelas_id = case when p_peran = 'siswa' then p_kelas_id end,
           aktif = coalesce(p_aktif, true),
           no_wa_ortu = case when p_peran = 'siswa' then hk__norm_hp(p_no_wa_ortu) end
     where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Pengguna tidak ditemukan.'; end if;
    if not coalesce(p_aktif, true) then delete from hk_sesi where pengguna_id = v_id; end if;
    if p_peran <> 'wali' then update hk_kelas set wali_id = null where wali_id = v_id; end if;
  end if;
  return v_id;
end $$;

-- Reset kata sandi menjadi = username/NISN, wajib ganti saat masuk
create or replace function public.hk_admin_reset_password(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin');
  update hk_pengguna
     set password_hash = crypt(username, gen_salt('bf', 8)),
         harus_ganti_password = true, gagal_login = 0, kunci_sampai = null
   where id = p_id;
  if not found then raise exception 'Pengguna tidak ditemukan.'; end if;
  delete from hk_sesi where pengguna_id = p_id;
end $$;

-- Impor siswa massal: p_data = [{"nisn":"...","nama":"...","kelas":"X-1","no_wa":"08..."}, ...]
create or replace function public.hk_admin_impor_siswa(p_token text, p_data jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token);
  e jsonb; v_nisn text; v_nama text; v_kelas text; v_kelas_id bigint; v_id bigint; v_peran text; v_wa text;
  n_baru int := 0; n_ubah int := 0; n_kelas int := 0; n_lewat int := 0; v_catatan text[] := '{}';
begin
  perform hk__wajib(u, 'admin');
  if jsonb_typeof(p_data) <> 'array' then raise exception 'Format data impor tidak valid.'; end if;
  if jsonb_array_length(p_data) > 2000 then raise exception 'Maksimal 2000 baris per impor.'; end if;

  for e in select * from jsonb_array_elements(p_data) loop
    v_nisn  := trim(coalesce(e->>'nisn', ''));
    v_nama  := trim(coalesce(e->>'nama', ''));
    v_kelas := trim(coalesce(e->>'kelas', ''));
    v_wa    := hk__norm_hp(e->>'no_wa');
    if v_nisn = '' or v_nama = '' or v_nisn !~ '^[A-Za-z0-9._-]{3,40}$' then
      n_lewat := n_lewat + 1;
      v_catatan := v_catatan || format('Dilewati: "%s" / "%s"', v_nisn, v_nama);
      continue;
    end if;

    v_kelas_id := null;
    if v_kelas <> '' then
      select id into v_kelas_id from hk_kelas where lower(nama) = lower(v_kelas);
      if v_kelas_id is null then
        insert into hk_kelas (nama) values (v_kelas) returning id into v_kelas_id;
        n_kelas := n_kelas + 1;
      end if;
    end if;

    v_id := null; v_peran := null;
    select id, peran into v_id, v_peran from hk_pengguna where lower(username) = lower(v_nisn);
    if v_id is null then
      insert into hk_pengguna (username, nama, peran, kelas_id, password_hash, harus_ganti_password, no_wa_ortu)
      values (v_nisn, v_nama, 'siswa', v_kelas_id, crypt(v_nisn, gen_salt('bf', 8)), true, v_wa);
      n_baru := n_baru + 1;
    elsif v_peran = 'siswa' then
      update hk_pengguna set nama = v_nama, kelas_id = coalesce(v_kelas_id, kelas_id),
                             no_wa_ortu = coalesce(v_wa, no_wa_ortu) where id = v_id;
      n_ubah := n_ubah + 1;
    else
      n_lewat := n_lewat + 1;
      v_catatan := v_catatan || format('Dilewati: "%s" sudah dipakai akun staf', v_nisn);
    end if;
  end loop;

  return json_build_object('baru', n_baru, 'diperbarui', n_ubah, 'kelas_baru', n_kelas,
                           'dilewati', n_lewat, 'catatan', to_json(v_catatan[1:20]));
end $$;

-- =====================================================================
-- 7b. RPC FASE 2 — perasaan, pengajuan izin, perlu disapa, notifikasi
-- =====================================================================

create or replace function public.hk__tgl_id(d date) returns text
language sql immutable as $$
  select (array['Senin','Selasa','Rabu','Kamis','Jumat','Sabtu','Minggu'])[extract(isodow from d)::int] || ', ' ||
         extract(day from d)::int || ' ' ||
         (array['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember'])[extract(month from d)::int] ||
         ' ' || extract(year from d)::int
$$;
create or replace function public.hk__rentang_id(a date, b date) returns text
language sql immutable as $$
  select case when a = b then hk__tgl_id(a) else hk__tgl_id(a) || ' s.d. ' || hk__tgl_id(b) end
$$;

-- ---------- Cek perasaan (setelah absen masuk) ----------
create or replace function public.hk_perasaan(p_token text, p_nilai int, p_cerita boolean default false) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_tgl date := hk__lokal()::date;
begin
  perform hk__wajib(u, 'siswa');
  if p_nilai is not null and p_nilai not between 1 and 5 then raise exception 'Pilihan perasaan tidak valid.'; end if;
  update hk_absensi set perasaan = p_nilai, ingin_cerita = coalesce(p_cerita, false), diubah = now()
   where siswa_id = u.id and tanggal = v_tgl and jam_masuk is not null;
  if not found then raise exception 'Absen masuk hari ini belum tercatat.'; end if;
end $$;

-- ---------- Pengajuan izin / sakit ----------
create or replace function public.hk_izin_ajukan(p_token text, p_jenis text, p_mulai date, p_selesai date,
                                                 p_alasan text, p_lampiran text default null, p_mime text default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg();
  v_hari_ini date := hk__lokal()::date; v_id bigint; v_data text;
begin
  perform hk__wajib(u, 'siswa');
  if p_jenis not in ('izin', 'sakit') then raise exception 'Pilih jenis: izin atau sakit.'; end if;
  if p_mulai is null or p_selesai is null then raise exception 'Tanggal mulai dan selesai wajib diisi.'; end if;
  if p_selesai < p_mulai then raise exception 'Tanggal selesai tidak boleh sebelum tanggal mulai.'; end if;
  if p_mulai < v_hari_ini - 3 then raise exception 'Pengajuan untuk tanggal yang sudah lewat maksimal 3 hari ke belakang. Selebihnya, temui wali kelas.'; end if;
  if p_mulai > v_hari_ini + 30 then raise exception 'Pengajuan paling jauh 30 hari ke depan.'; end if;
  if p_selesai - p_mulai > 13 then raise exception 'Satu pengajuan maksimal 14 hari.'; end if;
  if length(trim(coalesce(p_alasan, ''))) < 5 then raise exception 'Tuliskan alasan minimal 5 karakter.'; end if;
  if not exists (select 1 from hk__hari_efektif(p_mulai, p_selesai)) then
    raise exception 'Tidak ada hari sekolah pada rentang tanggal tersebut.';
  end if;
  if exists (select 1 from hk_pengajuan p where p.siswa_id = u.id and p.status in ('menunggu', 'disetujui')
              and daterange(p.tgl_mulai, p.tgl_selesai, '[]') && daterange(p_mulai, p_selesai, '[]')) then
    raise exception 'Sudah ada pengajuan lain pada tanggal tersebut.';
  end if;

  v_data := nullif(regexp_replace(coalesce(p_lampiran, ''), '^data:[^,]*,', ''), '');
  if v_data is not null then
    if coalesce(p_mime, '') not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Bukti harus berupa foto (JPG/PNG/WEBP).'; end if;
    if length(v_data) > 1400000 then raise exception 'Foto bukti terlalu besar (maks. ±1 MB).'; end if;
    if v_data !~ '^[A-Za-z0-9+/=]+$' then raise exception 'Data foto tidak valid.'; end if;
  end if;

  insert into hk_pengajuan (siswa_id, jenis, tgl_mulai, tgl_selesai, alasan)
  values (u.id, p_jenis, p_mulai, p_selesai, trim(p_alasan)) returning id into v_id;
  if v_data is not null then
    insert into hk_lampiran (pengajuan_id, mime, data_b64) values (v_id, p_mime, v_data);
  end if;

  if c.notif_izin then
    perform hk__notif(u.id, 'pengajuan', v_hari_ini, v_id,
      format('Assalamu''alaikum, Bapak/Ibu. Ananda %s mengajukan %s untuk %s dengan alasan: "%s". Jika Bapak/Ibu tidak mengetahui pengajuan ini, mohon hubungi wali kelas. — HadirKuy',
             u.nama, p_jenis, hk__rentang_id(p_mulai, p_selesai), left(trim(p_alasan), 160)));
    begin perform hk__kirim_antrean(5); exception when others then null; end;
  end if;
  return v_id;
end $$;

create or replace function public.hk_izin_saya(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'siswa');
  return coalesce((
    select json_agg(x order by x.dibuat_ts desc) from (
      select p.id, p.jenis, p.tgl_mulai, p.tgl_selesai, p.alasan, p.status, p.catatan_wali,
             p.dibuat as dibuat_ts, hk__fmt_jam(p.dibuat) as jam_dibuat, (p.dibuat at time zone (select zona_waktu from hk_pengaturan where id = 1))::date as tgl_dibuat,
             (select count(*) from hk__hari_efektif(p.tgl_mulai, p.tgl_selesai)) as jumlah_hari,
             exists (select 1 from hk_lampiran l where l.pengajuan_id = p.id) as ada_lampiran,
             w.nama as diputus_oleh
      from hk_pengajuan p left join hk_pengguna w on w.id = p.diputus_oleh
      where p.siswa_id = u.id
      order by p.dibuat desc limit 50) x), '[]'::json);
end $$;

create or replace function public.hk_izin_batal(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'siswa');
  update hk_pengajuan set status = 'dibatalkan' where id = p_id and siswa_id = u.id and status = 'menunggu';
  if not found then raise exception 'Pengajuan tidak dapat dibatalkan (mungkin sudah diputuskan).'; end if;
end $$;

create or replace function public.hk_izin_lampiran(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); p hk_pengajuan; s hk_pengguna; l hk_lampiran;
begin
  select * into p from hk_pengajuan where id = p_id;
  if p.id is null then raise exception 'Pengajuan tidak ditemukan.'; end if;
  select * into s from hk_pengguna where id = p.siswa_id;
  if not (u.id = s.id or (u.peran in ('admin', 'kepala', 'bk', 'wali') and hk__boleh_kelas(u, s.kelas_id))) then
    raise exception 'Anda tidak memiliki akses ke bukti ini.';
  end if;
  select * into l from hk_lampiran where pengajuan_id = p_id;
  if l.pengajuan_id is null then raise exception 'Pengajuan ini tidak memiliki foto bukti.'; end if;
  return json_build_object('mime', l.mime, 'data', l.data_b64);
end $$;

create or replace function public.hk_izin_daftar(p_token text, p_status text default 'menunggu', p_kelas_id bigint default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  if p_kelas_id is not null and not hk__boleh_kelas(u, p_kelas_id) then raise exception 'Anda tidak memiliki akses ke kelas ini.'; end if;
  return coalesce((
    select json_agg(x order by x.menunggu desc, x.dibuat_ts desc) from (
      select p.id, p.siswa_id, s.nama, s.username as nisn, k.nama as kelas, p.jenis, p.tgl_mulai, p.tgl_selesai,
             p.alasan, p.status, p.catatan_wali, (p.status = 'menunggu') as menunggu,
             p.dibuat as dibuat_ts, (p.dibuat at time zone (select zona_waktu from hk_pengaturan where id = 1))::date as tgl_dibuat, hk__fmt_jam(p.dibuat) as jam_dibuat,
             (select count(*) from hk__hari_efektif(p.tgl_mulai, p.tgl_selesai)) as jumlah_hari,
             exists (select 1 from hk_lampiran l where l.pengajuan_id = p.id) as ada_lampiran,
             w.nama as diputus_oleh
      from hk_pengajuan p
      join hk_pengguna s on s.id = p.siswa_id
      left join hk_kelas k on k.id = s.kelas_id
      left join hk_pengguna w on w.id = p.diputus_oleh
      where (nullif(p_status, '') is null or p.status = p_status)
        and (p_kelas_id is null or s.kelas_id = p_kelas_id)
        and (u.peran <> 'wali' or hk__boleh_kelas(u, s.kelas_id))
      order by p.dibuat desc limit 300) x), '[]'::json);
end $$;

create or replace function public.hk_izin_putuskan(p_token text, p_id bigint, p_setuju boolean, p_catatan text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg(); p hk_pengajuan; s hk_pengguna; d date;
begin
  perform hk__wajib(u, 'admin', 'wali');
  select * into p from hk_pengajuan where id = p_id for update;
  if p.id is null then raise exception 'Pengajuan tidak ditemukan.'; end if;
  if p.status <> 'menunggu' then raise exception 'Pengajuan ini sudah %.', p.status; end if;
  select * into s from hk_pengguna where id = p.siswa_id;
  if u.peran = 'wali' and not hk__boleh_kelas(u, s.kelas_id) then
    raise exception 'Anda hanya dapat memutuskan pengajuan siswa di kelas perwalian Anda.';
  end if;
  if not p_setuju and length(trim(coalesce(p_catatan, ''))) < 3 then
    raise exception 'Tuliskan alasan penolakan agar siswa memahami.';
  end if;

  update hk_pengajuan
     set status = case when p_setuju then 'disetujui' else 'ditolak' end,
         catatan_wali = nullif(trim(coalesce(p_catatan, '')), ''), diputus_oleh = u.id, diputus = now()
   where id = p.id;

  if p_setuju then
    for d in select tgl from hk__hari_efektif(p.tgl_mulai, p.tgl_selesai) as h(tgl) loop
      insert into hk_absensi (siswa_id, tanggal, status, keterangan, sumber, pengajuan_id, diubah_oleh, diubah)
      values (s.id, d, p.jenis, left(p.alasan, 200), 'pengajuan', p.id, u.id, now())
      on conflict (siswa_id, tanggal) do update
        set status = excluded.status, keterangan = excluded.keterangan, sumber = 'pengajuan',
            pengajuan_id = excluded.pengajuan_id, diubah_oleh = excluded.diubah_oleh, diubah = now()
        where hk_absensi.jam_masuk is null;   -- bila siswa ternyata hadir, kehadiran tetap dipakai
    end loop;
  end if;

  if c.notif_izin then
    perform hk__notif(s.id, case when p_setuju then 'izin_disetujui' else 'izin_ditolak' end, hk__lokal()::date, p.id,
      case when p_setuju
        then format('Assalamu''alaikum, Bapak/Ibu. Pengajuan %s Ananda %s untuk %s telah DISETUJUI wali kelas.%s Semoga Ananda selalu dalam lindungan Allah. — HadirKuy',
                    p.jenis, s.nama, hk__rentang_id(p.tgl_mulai, p.tgl_selesai),
                    case when p.jenis = 'sakit' then ' Semoga lekas sembuh.' else '' end)
        else format('Assalamu''alaikum, Bapak/Ibu. Pengajuan %s Ananda %s untuk %s belum dapat disetujui wali kelas. Catatan: "%s". Mohon hubungi wali kelas untuk informasi lebih lanjut. — HadirKuy',
                    p.jenis, s.nama, hk__rentang_id(p.tgl_mulai, p.tgl_selesai), trim(p_catatan)) end);
    begin perform hk__kirim_antrean(5); exception when others then null; end;
  end if;
end $$;

-- ---------- Perlu Disapa (peringatan dini) & tindak lanjut ----------
create or replace function public.hk_peringatan(p_token text, p_kelas_id bigint default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_pribadi boolean; v_hari_ini date := hk__lokal()::date;
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  if p_kelas_id is not null and not hk__boleh_kelas(u, p_kelas_id) then raise exception 'Anda tidak memiliki akses ke kelas ini.'; end if;
  v_pribadi := u.peran in ('wali', 'bk', 'admin');
  return coalesce((
    select json_agg(x order by x.skor desc, x.nama) from (
      select y.*, (least(y.alpa_beruntun, 10) * 3 + y.terlambat_14 + y.rendah_7 * 2 + case when y.ingin_cerita then 4 else 0 end) as skor
      from (
        select s.id, s.nama, s.username as nisn, k.nama as kelas, s.no_wa_ortu,
               hk__alpa_beruntun(s.id) as alpa_beruntun,
               (select count(*) from hk_absensi a where a.siswa_id = s.id and a.status = 'terlambat' and a.tanggal > v_hari_ini - 14)::int as terlambat_14,
               case when v_pribadi then (select count(*) from hk_absensi a where a.siswa_id = s.id and a.perasaan <= 2 and a.tanggal > v_hari_ini - 7)::int else 0 end as rendah_7,
               case when v_pribadi then exists (
                 select 1 from hk_absensi a where a.siswa_id = s.id and a.ingin_cerita and a.tanggal > v_hari_ini - 7
                   and not exists (select 1 from hk_tindak_lanjut t where t.siswa_id = s.id
                                   and (t.dibuat at time zone (select zona_waktu from hk_pengaturan where id = 1))::date >= a.tanggal))
               else false end as ingin_cerita,
               (select json_build_object('jenis', t.jenis, 'catatan', t.catatan, 'oleh', o.nama,
                        'tanggal', (t.dibuat at time zone (select zona_waktu from hk_pengaturan where id = 1))::date)
                  from hk_tindak_lanjut t left join hk_pengguna o on o.id = t.oleh
                 where t.siswa_id = s.id order by t.dibuat desc limit 1) as tindak_lanjut
        from hk_pengguna s left join hk_kelas k on k.id = s.kelas_id
        where s.peran = 'siswa' and s.aktif
          and (p_kelas_id is null or s.kelas_id = p_kelas_id)
          and (u.peran <> 'wali' or hk__boleh_kelas(u, s.kelas_id))
      ) y
      where y.alpa_beruntun >= 3 or y.terlambat_14 >= 3 or y.rendah_7 >= 2 or y.ingin_cerita
    ) x), '[]'::json);
end $$;

create or replace function public.hk_tindak_lanjut_simpan(p_token text, p_siswa bigint, p_jenis text, p_catatan text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); s hk_pengguna;
begin
  perform hk__wajib(u, 'admin', 'bk', 'wali');
  select * into s from hk_pengguna where id = p_siswa and peran = 'siswa';
  if s.id is null then raise exception 'Siswa tidak ditemukan.'; end if;
  if not hk__boleh_kelas(u, s.kelas_id) then raise exception 'Anda tidak memiliki akses ke siswa ini.'; end if;
  if length(trim(coalesce(p_catatan, ''))) < 3 then raise exception 'Tuliskan catatan singkat tindak lanjut.'; end if;
  insert into hk_tindak_lanjut (siswa_id, oleh, jenis, catatan) values (s.id, u.id, p_jenis, left(trim(p_catatan), 1000));
end $$;

create or replace function public.hk_tindak_lanjut_daftar(p_token text, p_siswa bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); s hk_pengguna;
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  select * into s from hk_pengguna where id = p_siswa and peran = 'siswa';
  if s.id is null or not hk__boleh_kelas(u, s.kelas_id) then raise exception 'Anda tidak memiliki akses ke siswa ini.'; end if;
  return coalesce((select json_agg(json_build_object('jenis', t.jenis, 'catatan', t.catatan, 'oleh', o.nama,
                    'tanggal', (t.dibuat at time zone (select zona_waktu from hk_pengaturan where id = 1))::date, 'jam', hk__fmt_jam(t.dibuat))
                    order by t.dibuat desc)
                  from hk_tindak_lanjut t left join hk_pengguna o on o.id = t.oleh where t.siswa_id = s.id), '[]'::json);
end $$;

-- ---------- Reset perangkat siswa (HP hilang/ganti) ----------
create or replace function public.hk_reset_perangkat(p_token text, p_siswa bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); s hk_pengguna;
begin
  perform hk__wajib(u, 'admin', 'wali');
  select * into s from hk_pengguna where id = p_siswa and peran = 'siswa';
  if s.id is null then raise exception 'Siswa tidak ditemukan.'; end if;
  if u.peran = 'wali' and not hk__boleh_kelas(u, s.kelas_id) then raise exception 'Anda hanya dapat mereset perangkat siswa di kelas perwalian Anda.'; end if;
  update hk_pengguna set perangkat_hash = null, perangkat_terikat = null where id = s.id;
end $$;

-- ---------- Notifikasi WhatsApp ----------
create or replace function public.hk_notif_daftar(p_token text, p_status text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg();
begin
  perform hk__wajib(u, 'admin', 'wali');
  perform hk__perbarui_status();
  return json_build_object(
    'gateway', c.wa_aktif and coalesce(c.wa_token, '') <> '' and to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is not null,
    'daftar', coalesce((
      select json_agg(x order by x.id desc) from (
        select n.id, n.jenis, n.tujuan, n.pesan, n.status, n.alasan, n.tanggal,
               hk__fmt_jam(n.dibuat) as jam, s.nama, k.nama as kelas
        from hk_notifikasi n
        left join hk_pengguna s on s.id = n.siswa_id
        left join hk_kelas k on k.id = s.kelas_id
        where (nullif(p_status, '') is null or n.status = p_status)
          and (u.peran = 'admin' or (n.siswa_id is not null and hk__boleh_kelas(u, s.kelas_id)))
        order by n.id desc limit 300) x), '[]'::json));
end $$;

create or replace function public.hk_notif_tandai(p_token text, p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); n hk_notifikasi; s hk_pengguna;
begin
  perform hk__wajib(u, 'admin', 'wali');
  if p_status not in ('terkirim', 'dibatalkan', 'antri') then raise exception 'Status tidak valid.'; end if;
  select * into n from hk_notifikasi where id = p_id;
  if n.id is null then raise exception 'Notifikasi tidak ditemukan.'; end if;
  select * into s from hk_pengguna where id = n.siswa_id;
  if u.peran <> 'admin' and (s.id is null or not hk__boleh_kelas(u, s.kelas_id)) then raise exception 'Akses ditolak.'; end if;
  update hk_notifikasi set status = p_status, alasan = case when p_status = 'terkirim' then 'Dikirim manual' end, diubah = now() where id = n.id;
  if p_status = 'antri' then begin perform hk__kirim_antrean(5); exception when others then null; end; end if;
end $$;

create or replace function public.hk_admin_wa_token(p_token text, p_wa_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin');
  update hk_pengaturan set wa_token = nullif(trim(coalesce(p_wa_token, '')), '') where id = 1;
end $$;

create or replace function public.hk_admin_wa_uji(p_token text, p_nomor text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg(); v_no text := hk__norm_hp(p_nomor); v_id bigint;
begin
  perform hk__wajib(u, 'admin');
  if v_no is null then raise exception 'Nomor WhatsApp tidak valid. Contoh: 081234567890.'; end if;
  insert into hk_notifikasi (siswa_id, tanggal, jenis, ref, tujuan, pesan)
  values (null, hk__lokal()::date, 'uji', floor(extract(epoch from now()))::bigint, v_no,
          format('Pesan uji dari HadirKuy %s. Jika pesan ini sampai, notifikasi WhatsApp sudah berfungsi. — HadirKuy', c.nama_madrasah))
  returning id into v_id;
  perform hk__kirim_antrean(5);
  return json_build_object('id', v_id, 'tujuan', v_no,
    'gateway', c.wa_aktif and coalesce(c.wa_token, '') <> '' and to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is not null);
end $$;

create or replace function public.hk_admin_proses(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  perform hk__wajib(u, 'admin');
  return hk__cron();
end $$;

-- =====================================================================
-- 7c. RPC FASE 3 — kartu QR & pos petugas, dasbor, rekap matriks, rapor
-- =====================================================================

-- ---------- Kartu QR Siswa (untuk siswa tanpa HP) ----------
create or replace function public.hk__kode_kartu() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare v text;
begin
  loop
    v := upper(substr(translate(encode(gen_random_bytes(12), 'base64'), '+/=01OIl', ''), 1, 10));
    exit when length(v) = 10 and not exists (select 1 from hk_pengguna where kartu_kode = v);
  end loop;
  return v;
end $$;

create or replace function public.hk_kartu_daftar(p_token text, p_kelas_id bigint default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); s record;
begin
  perform hk__wajib(u, 'admin', 'wali');
  if p_kelas_id is not null and not hk__boleh_kelas(u, p_kelas_id) then raise exception 'Anda tidak memiliki akses ke kelas ini.'; end if;
  if p_kelas_id is null and u.peran = 'wali' then raise exception 'Pilih kelas terlebih dahulu.'; end if;
  for s in select id from hk_pengguna
           where peran = 'siswa' and aktif and kartu_kode is null and (p_kelas_id is null or kelas_id = p_kelas_id) loop
    update hk_pengguna set kartu_kode = hk__kode_kartu() where id = s.id;
  end loop;
  return coalesce((
    select json_agg(json_build_object('id', p.id, 'nisn', p.username, 'nama', p.nama, 'kelas', k.nama, 'kode', p.kartu_kode,
                                      'ada_foto', exists (select 1 from hk_foto f where f.pengguna_id = p.id))
                    order by k.nama nulls last, p.nama)
    from hk_pengguna p left join hk_kelas k on k.id = p.kelas_id
    where p.peran = 'siswa' and p.aktif and (p_kelas_id is null or p.kelas_id = p_kelas_id)), '[]'::json);
end $$;

-- Kartu hilang: buat kode baru (kartu lama otomatis tidak berlaku)
create or replace function public.hk_kartu_ganti(p_token text, p_siswa bigint) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); s hk_pengguna; v text;
begin
  perform hk__wajib(u, 'admin', 'wali');
  select * into s from hk_pengguna where id = p_siswa and peran = 'siswa';
  if s.id is null then raise exception 'Siswa tidak ditemukan.'; end if;
  if u.peran = 'wali' and not hk__boleh_kelas(u, s.kelas_id) then raise exception 'Anda hanya dapat mengganti kartu siswa di kelas perwalian Anda.'; end if;
  v := hk__kode_kartu();
  update hk_pengguna set kartu_kode = v where id = s.id;
  return v;
end $$;

-- Pos petugas: pindai Kartu QR (p_kode) atau pilih siswa manual (p_siswa).
-- p_waktu diisi bila scan dilakukan saat offline (antrean di HP petugas).
create or replace function public.hk_pos_absen(p_token text, p_kode text default null, p_siswa bigint default null,
                                               p_jenis text default 'otomatis', p_waktu timestamptz default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg();
  s hk_pengguna; v_kode text; v_waktu timestamptz := coalesce(p_waktu, now());
  v_tgl date; v_jenis text; r hk_absensi;
begin
  perform hk__wajib(u, 'admin', 'petugas');
  if v_waktu > now() + interval '2 minutes' or v_waktu < now() - interval '24 hours' then
    raise exception 'Waktu scan tidak valid (lebih dari 24 jam). Catat manual lewat wali kelas.';
  end if;
  if p_kode is not null then
    v_kode := upper(regexp_replace(trim(p_kode), '^HKKARTU\|', '', 'i'));
    select * into s from hk_pengguna where kartu_kode = v_kode and peran = 'siswa';
    if s.id is null then raise exception 'Kartu tidak dikenali atau sudah diganti. Minta wali kelas mencetak kartu baru.'; end if;
  elsif p_siswa is not null then
    select * into s from hk_pengguna where id = p_siswa and peran = 'siswa';
    if s.id is null then raise exception 'Siswa tidak ditemukan.'; end if;
  else
    raise exception 'Pindai kartu atau pilih siswa.';
  end if;
  if not s.aktif then raise exception 'Akun % dinonaktifkan.', s.nama; end if;

  v_tgl := (v_waktu at time zone c.zona_waktu)::date;
  v_jenis := p_jenis;
  if coalesce(v_jenis, 'otomatis') = 'otomatis' then
    select * into r from hk_absensi where siswa_id = s.id and tanggal = v_tgl;
    v_jenis := case when r.jam_masuk is not null and r.jam_pulang is null
                         and (v_waktu at time zone c.zona_waktu)::time >= hk__jam_pulang(v_tgl) then 'pulang'
                    else 'masuk' end;
  end if;
  if v_jenis not in ('masuk', 'pulang') then raise exception 'Jenis absen tidak valid.'; end if;
  return hk__catat_absen(s, v_jenis, v_waktu, true, null, case when p_kode is not null then 'kartu' else 'pos' end);
end $$;

create or replace function public.hk_pos_cari(p_token text, p_q text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_tgl date := hk__lokal()::date;
begin
  perform hk__wajib(u, 'admin', 'petugas');
  if length(trim(coalesce(p_q, ''))) < 2 then return '[]'::json; end if;
  return coalesce((
    select json_agg(x) from (
      select p.id, p.username as nisn, p.nama, k.nama as kelas,
             hk__fmt_jam(a.jam_masuk) as jam_masuk, hk__fmt_jam(a.jam_pulang) as jam_pulang, a.status
      from hk_pengguna p left join hk_kelas k on k.id = p.kelas_id
      left join hk_absensi a on a.siswa_id = p.id and a.tanggal = v_tgl
      where p.peran = 'siswa' and p.aktif and (p.nama ilike '%' || trim(p_q) || '%' or p.username ilike trim(p_q) || '%')
      order by p.nama limit 10) x), '[]'::json);
end $$;

-- ---------- Grid kehadiran: satu baris per siswa per hari efektif yang sudah berjalan ----------
create or replace function public.hk__grid(p_dari date, p_sampai date, p_kelas bigint default null)
returns table (siswa_id bigint, kelas_id bigint, tanggal date, status text, menit int, perasaan smallint)
language sql stable set search_path = public as $$
  with c as (select * from hk_pengaturan where id = 1),
  s as (
    select p.id, p.kelas_id, greatest(c.tanggal_mulai, (p.dibuat at time zone c.zona_waktu)::date) as mulai
    from hk_pengguna p, c
    where p.peran = 'siswa' and p.aktif and (p_kelas is null or p.kelas_id = p_kelas)
  ),
  h as (select tgl from hk__hari_efektif(p_dari, least(p_sampai, hk__lokal()::date)) as h(tgl))
  select s.id, s.kelas_id, h.tgl, coalesce(a.status, 'alpa'), coalesce(a.menit_terlambat, 0), a.perasaan
  from s join h on h.tgl >= s.mulai
  left join hk_absensi a on a.siswa_id = s.id and a.tanggal = h.tgl
  where h.tgl <= hk__batas_alpa() or a.id is not null
$$;

-- Status hari ini per siswa aktif (termasuk "belum")
create or replace function public.hk__status_hari_ini(p_kelas bigint default null)
returns table (siswa_id bigint, kelas_id bigint, status text)
language sql stable set search_path = public as $$
  with c as (select * from hk_pengaturan where id = 1),
  t as (select hk__lokal()::date as tgl),
  ef as (select exists (select 1 from hk__hari_efektif((select tgl from t), (select tgl from t))) as ok)
  select p.id, p.kelas_id,
         coalesce(a.status, case when (select ok from ef) and (select tgl from t) >= greatest(c.tanggal_mulai, (p.dibuat at time zone c.zona_waktu)::date)
                                 then case when (select tgl from t) <= hk__batas_alpa() then 'alpa' else 'belum' end end)
  from hk_pengguna p cross join c
  left join hk_absensi a on a.siswa_id = p.id and a.tanggal = (select tgl from t)
  where p.peran = 'siswa' and p.aktif and (p_kelas is null or p.kelas_id = p_kelas)
$$;

-- ---------- Dasbor kepala madrasah ----------
create or replace function public.hk_dash_madrasah(p_token text, p_dari date default null, p_sampai date default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  u hk_pengguna := hk__user(p_token);
  v_sampai date := least(coalesce(p_sampai, hk__lokal()::date), hk__lokal()::date);
  v_dari date := coalesce(p_dari, v_sampai - 29);
  v_hasil json;
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk');
  if v_dari > v_sampai then raise exception 'Tanggal awal harus sebelum tanggal akhir.'; end if;
  if v_sampai - v_dari > 200 then raise exception 'Rentang maksimal 200 hari.'; end if;

  with g0 as materialized (select * from hk__grid(v_dari, v_sampai))
  select json_build_object(
    'periode', json_build_object('dari', v_dari, 'sampai', v_sampai),
    'jumlah_siswa', (select count(*) from hk_pengguna where peran = 'siswa' and aktif),
    'jumlah_kelas', (select count(*) from hk_kelas),
    'hari_ini', (select json_build_object(
        'hadir', count(*) filter (where status = 'hadir'), 'terlambat', count(*) filter (where status = 'terlambat'),
        'izin', count(*) filter (where status = 'izin'), 'sakit', count(*) filter (where status = 'sakit'),
        'alpa', count(*) filter (where status = 'alpa'), 'belum', count(*) filter (where status = 'belum'),
        'efektif', count(*) filter (where status is not null))
      from hk__status_hari_ini()),
    'ringkas', (select json_build_object(
        'hari_siswa', count(*), 'hadir', count(*) filter (where status = 'hadir'),
        'terlambat', count(*) filter (where status = 'terlambat'), 'izin', count(*) filter (where status = 'izin'),
        'sakit', count(*) filter (where status = 'sakit'), 'alpa', count(*) filter (where status = 'alpa'),
        'hari_efektif', count(distinct tanggal)) from g0),
    'tren', coalesce((select json_agg(x order by x.tanggal) from (
        select tanggal, count(*) as total,
               count(*) filter (where status in ('hadir', 'terlambat')) as hadir,
               count(*) filter (where status = 'terlambat') as terlambat,
               count(*) filter (where status in ('izin', 'sakit')) as izin_sakit,
               count(*) filter (where status = 'alpa') as alpa
        from g0 group by tanggal) x), '[]'::json),
    'per_kelas', coalesce((select json_agg(x order by x.persen nulls last, x.nama) from (
        select k.id, k.nama, w.nama as wali,
               (select count(*) from hk_pengguna s where s.kelas_id = k.id and s.peran = 'siswa' and s.aktif) as siswa,
               count(g.*) as hari_siswa,
               count(g.*) filter (where g.status in ('hadir', 'terlambat')) as hadir,
               count(g.*) filter (where g.status = 'terlambat') as terlambat,
               count(g.*) filter (where g.status in ('izin', 'sakit')) as izin_sakit,
               count(g.*) filter (where g.status = 'alpa') as alpa,
               round(100.0 * count(g.*) filter (where g.status in ('hadir', 'terlambat')) / nullif(count(g.*), 0), 1) as persen,
               (select count(*) from (select g2.siswa_id from g0 g2 where g2.kelas_id = k.id group by g2.siswa_id
                  having count(*) >= 5 and count(*) filter (where g2.status in ('izin', 'sakit', 'alpa')) >= 0.1 * count(*)) z) as kronis
        from hk_kelas k left join hk_pengguna w on w.id = k.wali_id
        left join g0 g on g.kelas_id = k.id
        group by k.id, k.nama, w.nama) x), '[]'::json),
    'kronis', coalesce((select json_agg(x order by x.persen_absen desc, x.nama) from (
        select g.siswa_id as id, p.nama, p.username as nisn, k.nama as kelas, count(*) as hari,
               count(*) filter (where g.status = 'alpa') as alpa, count(*) filter (where g.status = 'izin') as izin,
               count(*) filter (where g.status = 'sakit') as sakit,
               round(100.0 * count(*) filter (where g.status in ('izin', 'sakit', 'alpa')) / count(*), 1) as persen_absen
        from g0 g join hk_pengguna p on p.id = g.siswa_id left join hk_kelas k on k.id = g.kelas_id
        group by g.siswa_id, p.nama, p.username, k.nama
        having count(*) >= 5 and count(*) filter (where g.status in ('izin', 'sakit', 'alpa')) >= 0.1 * count(*)
        order by 9 desc limit 30) x), '[]'::json),
    'telat_hari', coalesce((select json_agg(x order by x.dow) from (
        select extract(isodow from tanggal)::int as dow, count(*) as total,
               count(*) filter (where status = 'terlambat') as terlambat
        from g0 group by 1) x), '[]'::json),
    -- perasaan hanya agregat sekolah (tanpa nama), dan hanya bila cukup banyak jawaban
    'perasaan', (select case when count(*) >= 10 then json_build_object(
        'n', count(*), '1', count(*) filter (where perasaan = 1), '2', count(*) filter (where perasaan = 2),
        '3', count(*) filter (where perasaan = 3), '4', count(*) filter (where perasaan = 4), '5', count(*) filter (where perasaan = 5)) end
      from g0 where perasaan is not null),
    'tindak_lanjut', (select count(*) from hk_tindak_lanjut t
        where (t.dibuat at time zone (select zona_waktu from hk_pengaturan where id = 1))::date between v_dari and v_sampai),
    'pengajuan_menunggu', (select count(*) from hk_pengajuan where status = 'menunggu'),
    'pengajuan_disetujui', (select count(*) from hk_pengajuan where status = 'disetujui' and tgl_mulai <= v_sampai and tgl_selesai >= v_dari)
  ) into v_hasil;
  return v_hasil;
end $$;

-- ---------- Dasbor wali kelas ----------
create or replace function public.hk_dash_kelas(p_token text, p_kelas_id bigint, p_tahun int, p_bulan int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); v_awal date; v_akhir date;
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  if p_kelas_id is null or not hk__boleh_kelas(u, p_kelas_id) then raise exception 'Anda tidak memiliki akses ke kelas ini.'; end if;
  v_awal := make_date(p_tahun, p_bulan, 1);
  v_akhir := (v_awal + interval '1 month' - interval '1 day')::date;
  return (
    with g as (select * from hk__grid(v_awal, v_akhir, p_kelas_id))
    select json_build_object(
      'kelas', (select json_build_object('id', k.id, 'nama', k.nama, 'wali', w.nama)
                from hk_kelas k left join hk_pengguna w on w.id = k.wali_id where k.id = p_kelas_id),
      'tahun', p_tahun, 'bulan', p_bulan,
      'hari_ini', (select json_build_object(
          'hadir', count(*) filter (where status = 'hadir'), 'terlambat', count(*) filter (where status = 'terlambat'),
          'izin', count(*) filter (where status = 'izin'), 'sakit', count(*) filter (where status = 'sakit'),
          'alpa', count(*) filter (where status = 'alpa'), 'belum', count(*) filter (where status = 'belum'),
          'siswa', count(*), 'efektif', count(*) filter (where status is not null))
        from hk__status_hari_ini(p_kelas_id)),
      'ringkas', (select json_build_object('hari_siswa', count(*),
          'hadir', count(*) filter (where status = 'hadir'), 'terlambat', count(*) filter (where status = 'terlambat'),
          'izin', count(*) filter (where status = 'izin'), 'sakit', count(*) filter (where status = 'sakit'),
          'alpa', count(*) filter (where status = 'alpa'), 'hari_efektif', count(distinct tanggal)) from g),
      'tren', coalesce((select json_agg(x order by x.tanggal) from (
          select tanggal, count(*) as total, count(*) filter (where status in ('hadir', 'terlambat')) as hadir,
                 count(*) filter (where status = 'terlambat') as terlambat
          from g group by tanggal) x), '[]'::json),
      'siswa', coalesce((select json_agg(x order by x.nama) from (
          select p.id, p.username as nisn, p.nama,
                 count(g.*) as hari, count(g.*) filter (where g.status = 'hadir') as hadir,
                 count(g.*) filter (where g.status = 'terlambat') as terlambat,
                 count(g.*) filter (where g.status = 'izin') as izin, count(g.*) filter (where g.status = 'sakit') as sakit,
                 count(g.*) filter (where g.status = 'alpa') as alpa
          from hk_pengguna p left join g on g.siswa_id = p.id
          where p.peran = 'siswa' and p.aktif and p.kelas_id = p_kelas_id
          group by p.id, p.username, p.nama) x), '[]'::json),
      'pengajuan_menunggu', (select count(*) from hk_pengajuan a join hk_pengguna p on p.id = a.siswa_id
                             where a.status = 'menunggu' and p.kelas_id = p_kelas_id)));
end $$;

-- ---------- Matriks rekap bulanan (untuk unduh Excel / cetak) ----------
create or replace function public.hk_rekap_matriks(p_token text, p_kelas_id bigint, p_tahun int, p_bulan int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg(); v_awal date; v_akhir date;
begin
  perform hk__wajib(u, 'admin', 'kepala', 'bk', 'wali');
  if p_kelas_id is null or not hk__boleh_kelas(u, p_kelas_id) then raise exception 'Anda tidak memiliki akses ke kelas ini.'; end if;
  v_awal := make_date(p_tahun, p_bulan, 1);
  v_akhir := (v_awal + interval '1 month' - interval '1 day')::date;
  return (
    with g as (select * from hk__grid(v_awal, v_akhir, p_kelas_id))
    select json_build_object(
      'madrasah', c.nama_madrasah, 'tahun', p_tahun, 'bulan', p_bulan,
      'kelas', (select nama from hk_kelas where id = p_kelas_id),
      'wali', (select w.nama from hk_kelas k join hk_pengguna w on w.id = k.wali_id where k.id = p_kelas_id),
      'hari', (select json_agg(json_build_object('tanggal', d::date,
                 'efektif', exists (select 1 from hk__hari_efektif(d::date, d::date)),
                 'libur', (select keterangan from hk_hari_libur where tanggal = d::date)) order by d)
               from generate_series(v_awal, v_akhir, interval '1 day') d),
      'siswa', coalesce((select json_agg(x order by x.nama) from (
          select p.username as nisn, p.nama,
                 coalesce((select json_object_agg(g.tanggal,
                            case g.status when 'hadir' then 'H' when 'terlambat' then 'T' when 'izin' then 'I'
                                          when 'sakit' then 'S' else 'A' end)
                           from g where g.siswa_id = p.id), '{}'::json) as kode,
                 (select count(*) from g where g.siswa_id = p.id and g.status = 'hadir') as hadir,
                 (select count(*) from g where g.siswa_id = p.id and g.status = 'terlambat') as terlambat,
                 (select count(*) from g where g.siswa_id = p.id and g.status = 'izin') as izin,
                 (select count(*) from g where g.siswa_id = p.id and g.status = 'sakit') as sakit,
                 (select count(*) from g where g.siswa_id = p.id and g.status = 'alpa') as alpa,
                 (select count(*) from g where g.siswa_id = p.id) as hari
          from hk_pengguna p where p.peran = 'siswa' and p.aktif and p.kelas_id = p_kelas_id) x), '[]'::json)));
end $$;

-- ---------- Rekap ketidakhadiran untuk rapor (S / I / A per rentang semester) ----------
create or replace function public.hk_rekap_rapor(p_token text, p_kelas_id bigint, p_dari date, p_sampai date) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); c hk_pengaturan := hk__cfg();
begin
  perform hk__wajib(u, 'admin', 'kepala', 'wali');
  if p_dari is null or p_sampai is null or p_dari > p_sampai then raise exception 'Rentang tanggal tidak valid.'; end if;
  if p_sampai - p_dari > 366 then raise exception 'Rentang maksimal satu tahun.'; end if;
  if p_kelas_id is not null and not hk__boleh_kelas(u, p_kelas_id) then raise exception 'Anda tidak memiliki akses ke kelas ini.'; end if;
  if p_kelas_id is null and u.peran = 'wali' then raise exception 'Pilih kelas terlebih dahulu.'; end if;
  return (
    with g as (select * from hk__grid(p_dari, p_sampai, p_kelas_id))
    select json_build_object('madrasah', c.nama_madrasah, 'dari', p_dari, 'sampai', p_sampai,
      'baris', coalesce((select json_agg(x order by x.kelas nulls last, x.nama) from (
          select p.username as nisn, p.nama, k.nama as kelas,
                 count(g.*) filter (where g.status = 'sakit') as sakit,
                 count(g.*) filter (where g.status = 'izin') as izin,
                 count(g.*) filter (where g.status = 'alpa') as alpa,
                 count(g.*) filter (where g.status = 'terlambat') as terlambat,
                 count(g.*) filter (where g.status in ('hadir', 'terlambat')) as hadir,
                 count(g.*) as hari_efektif
          from hk_pengguna p left join hk_kelas k on k.id = p.kelas_id
          left join g on g.siswa_id = p.id
          where p.peran = 'siswa' and p.aktif and (p_kelas_id is null or p.kelas_id = p_kelas_id)
          group by p.id, p.username, p.nama, k.nama) x), '[]'::json)));
end $$;

-- =====================================================================
-- 7d. RPC FOTO PROFIL
-- Siswa boleh mengunggah fotonya sendiri selama belum diverifikasi.
-- Foto yang diunggah wali kelas/admin dianggap terverifikasi (dipakai di
-- Kartu QR dan layar Pos Scan untuk mencocokkan wajah).
-- =====================================================================
create or replace function public.hk__boleh_foto(u public.hk_pengguna, t public.hk_pengguna, p_ubah boolean) returns boolean
language plpgsql stable set search_path = public as $$
begin
  if t.id is null then return false; end if;
  if u.id = t.id or u.peran = 'admin' then return true; end if;
  if u.peran = 'wali' then return t.peran = 'siswa' and hk__boleh_kelas(u, t.kelas_id); end if;
  if not p_ubah and u.peran in ('kepala', 'bk') then return true; end if;
  if not p_ubah and u.peran = 'petugas' then return t.peran = 'siswa'; end if;   -- verifikasi wajah di pos
  return false;
end $$;

create or replace function public.hk_foto_simpan(p_token text, p_data text, p_mime text default 'image/jpeg', p_pengguna bigint default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); t hk_pengguna; f hk_foto; v_data text; v_ver boolean;
begin
  select * into t from hk_pengguna where id = coalesce(p_pengguna, u.id);
  if not hk__boleh_foto(u, t, true) then raise exception 'Anda tidak dapat mengubah foto pengguna ini.'; end if;
  select * into f from hk_foto where pengguna_id = t.id;
  if u.id = t.id and u.peran = 'siswa' and f.terverifikasi then
    raise exception 'Fotomu sudah diverifikasi wali kelas. Minta wali kelas bila ingin menggantinya.';
  end if;
  v_data := regexp_replace(coalesce(p_data, ''), '^data:[^,]*,', '');
  if coalesce(p_mime, '') not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Foto harus JPG, PNG, atau WEBP.'; end if;
  if length(v_data) < 100 or v_data !~ '^[A-Za-z0-9+/=]+$' then raise exception 'Data foto tidak valid.'; end if;
  if length(v_data) > 400000 then raise exception 'Foto terlalu besar. Coba foto ulang.'; end if;
  v_ver := u.id <> t.id or u.peran <> 'siswa';
  insert into hk_foto (pengguna_id, mime, data_b64, oleh, terverifikasi, diubah)
  values (t.id, p_mime, v_data, u.id, v_ver, now())
  on conflict (pengguna_id) do update
    set mime = excluded.mime, data_b64 = excluded.data_b64, oleh = excluded.oleh,
        terverifikasi = excluded.terverifikasi, diubah = now();
  return json_build_object('pengguna_id', t.id, 'terverifikasi', v_ver,
    'versi', (select floor(extract(epoch from diubah))::bigint from hk_foto where pengguna_id = t.id));
end $$;

create or replace function public.hk_foto_hapus(p_token text, p_pengguna bigint default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token); t hk_pengguna; f hk_foto;
begin
  select * into t from hk_pengguna where id = coalesce(p_pengguna, u.id);
  if not hk__boleh_foto(u, t, true) then raise exception 'Anda tidak dapat menghapus foto pengguna ini.'; end if;
  select * into f from hk_foto where pengguna_id = t.id;
  if u.id = t.id and u.peran = 'siswa' and f.terverifikasi then
    raise exception 'Fotomu sudah diverifikasi wali kelas. Minta wali kelas bila ingin menggantinya.';
  end if;
  delete from hk_foto where pengguna_id = t.id;
end $$;

-- Ambil beberapa foto sekaligus (maks. 60): { "<id>": {"mime":..,"data":..,"versi":..,"terverifikasi":..} }
create or replace function public.hk_foto_ambil(p_token text, p_ids bigint[]) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hk_pengguna := hk__user(p_token);
begin
  if coalesce(array_length(p_ids, 1), 0) > 60 then raise exception 'Maksimal 60 foto per permintaan.'; end if;
  return coalesce((
    select json_object_agg(f.pengguna_id, json_build_object('mime', f.mime, 'data', f.data_b64,
             'versi', floor(extract(epoch from f.diubah))::bigint, 'terverifikasi', f.terverifikasi))
    from hk_foto f join hk_pengguna t on t.id = f.pengguna_id
    where f.pengguna_id = any (p_ids) and hk__boleh_foto(u, t, false)), '{}'::json);
end $$;

-- =====================================================================
-- 8. HAK AKSES FUNGSI
--    hk__* (internal) → tertutup;  hk_* (RPC) → boleh dipanggil klien,
--    tetapi setiap RPC tetap memeriksa token & peran sendiri.
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'hk\_%'
  loop
    execute format('revoke all on function %s from public', f.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', f.sig);
      if f.proname not like 'hk\_\_%' then
        execute format('grant execute on function %s to anon, authenticated', f.sig);
      end if;
    end if;
  end loop;
end $$;

-- =====================================================================
-- 9. (OPSIONAL) pg_net + pg_cron untuk WhatsApp otomatis
--    Bila gagal di sini, aktifkan manual: Database > Extensions > pg_net
--    dan pg_cron, lalu jalankan ulang file ini. Tanpa keduanya, aplikasi
--    tetap jalan: pesan masuk antrean dan bisa dikirim manual.
-- =====================================================================
do $$
begin
  begin
    create extension if not exists pg_net;
  exception when others then raise notice 'pg_net belum aktif: %', sqlerrm;
  end;
  begin
    create extension if not exists pg_cron;
  exception when others then raise notice 'pg_cron belum aktif: %', sqlerrm;
  end;
  if to_regclass('cron.job') is not null then
    begin
      perform cron.unschedule(jobid) from cron.job where jobname = 'hadirkuy-cron';
      perform cron.schedule('hadirkuy-cron', '* * * * *', 'select public.hk__cron()');
      raise notice 'Jadwal hadirkuy-cron aktif (tiap menit).';
    exception when others then raise notice 'Gagal menjadwalkan pg_cron: %', sqlerrm;
    end;
  end if;
end $$;

-- Selesai. Langkah berikutnya:
--  1) Isi SUPABASE_URL & SUPABASE_ANON_KEY di index.html
--  2) Masuk sebagai admin / admin123 → ganti kata sandi
--  3) Pengaturan: isi titik lokasi madrasah, jam, hari libur
--  4) Pengguna: impor siswa (CSV), buat akun wali kelas & petugas
--  5) Kelas: tetapkan wali kelas
--  6) Buka Layar QR di perangkat dekat gerbang
--  7) (Fase 2) Isi No. WA orang tua (impor CSV kolom ke-4 / menu Pengguna)
--  8) (Fase 2) Pengaturan > WhatsApp: isi token Fonnte, aktifkan, kirim pesan uji
