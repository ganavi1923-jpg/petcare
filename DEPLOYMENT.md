# Production Deployment Guide

## 1. Supabase setup

1. Create or select the intended Supabase project.
2. In Supabase SQL Editor, apply `database/schema.sql` to a database that has not already been initialized.
3. For an existing database, apply migrations in this order:
   1. `database/migrations/20261030_add_pets_is_listed.sql`
   2. `database/migrations/20261030_enforce_active_accounts_and_listed_vaccinations.sql`
   3. `database/migrations/20261030_add_pet_care_video_storage.sql`
   4. `database/migrations/20261030_replace_unavailable_pet_videos.sql`
   5. `database/migrations/20261030_add_dog_training_videos.sql`
4. Review every migration result set and verify that no migration reported a missing table or conflicting row.
5. Do not run `database/update_20_dogs.sql` or `database/seed.sql` against production data unless the existing data has been intentionally scoped and backed up.

## 2. Migration verification

Verify these live objects in Supabase:

- `public.pets.is_listed` exists and defaults to `true`.
- `public.pet_care_videos` exists with public read RLS.
- `public.users.status`, `public.users.role`, `public.vaccination_records`, adoption, appointment, support, and notification tables exist.
- `public.is_active_user()` exists and is executable only by authenticated users.
- Storage bucket `pet-care-videos` exists, is private, has a 100 MB video limit, and allows MP4, WebM, MOV, JPEG, PNG, and WebP.
- Storage object policies permit public reads only for published catalog paths and admin-only insert/update/delete operations.
- The live database owner should verify policies in the Supabase SQL Editor and Storage dashboard. This repository cannot inspect database-owner policy catalogs or execute SQL through the backend without a dedicated migration connection.

Do not delete or overwrite existing table or bucket data.

## 3. Required environment variables

Set these on the backend host:

| Variable | Required | Notes |
|---|---:|---|
| `NODE_ENV` | Yes | Set to `production` |
| `PORT` | Recommended | Hosting providers usually set this automatically |
| `FRONTEND_URL` | Yes | Exact HTTPS origin of the deployed frontend, with no trailing path |
| `SUPABASE_URL` | Yes | Supabase project URL |
| `SUPABASE_ANON_KEY` | Yes | Public/publishable key |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes | Server-only key; never place in frontend files or hosting frontend variables |

Optional:

| Variable | Notes |
|---|---|
| `OPENAI_API_KEY` | Enables the optional backend chatbot |
| `OPENAI_MODEL` | Defaults to `gpt-4o-mini` |
| `OPENAI_API_URL` | Optional OpenAI-compatible endpoint |

Copy `backend/.env.example` only for local setup. Never commit `.env` or a real service-role key.

## 4. Backend deployment

1. Deploy the `backend/` application directory or repository root to a Node.js host.
2. Use `npm install --omit=dev` and `npm start`.
3. Set all required environment variables.
4. Confirm `https://<backend-host>/api/health` returns HTTP 200.
5. Confirm `https://<backend-host>/api/test-supabase` succeeds after migrations.

The server serves `frontend/` when both run on the same origin. For a separately hosted static frontend, set `FRONTEND_URL` to the exact frontend origin and set `PAWCARE_BACKEND_URL` or a `pawcare-backend-url` meta tag in the static frontend.

Example frontend meta tag:

```html
<meta name="pawcare-backend-url" content="https://api.example.com" />
```

Do not add `/api` to `PAWCARE_BACKEND_URL`; `config.js` appends `/api`.

## 5. Frontend deployment

Use `frontend/` as the static output for a static host. No frontend build command is required.

Before deployment:

1. Set the real public Supabase URL and publishable/anon key in `frontend/js/config.js`.
2. Configure the backend URL through `meta name="pawcare-backend-url"` or `window.PAWCARE_BACKEND_URL`.
3. Remove or replace all localhost assumptions for the deployed origin.
4. Confirm CDN assets load over HTTPS.
5. Mirror intentional frontend changes into `public/` if that directory is used as the Vercel/static deployment source.

The `api/` directory provides an Express serverless-adapter attempt for Vercel. The existing backend must be tested as serverless before production use because serverless execution and WebSockets/uploads need host-specific limits.

## 6. Supabase Auth redirects

In Supabase Dashboard, configure Authentication > URL Configuration:

- Site URL: exact production frontend origin.
- Allowed Redirect URLs:
  - `https://<frontend-host>/reset-password.html`
  - `https://<frontend-host>/login.html`
  - `https://<frontend-host>/dashboard.html`
- Add local URLs only for development.

Enable email confirmation for production. Registration currently refuses production sessions unless email confirmation is configured.

Test registration, email confirmation, login, logout, session refresh, forgot-password email, password update, suspended-account rejection, and admin role enforcement.

## 7. CORS

`FRONTEND_URL` is allowlisted exactly. In production, localhost origins are not allowlisted. Requests without an Origin header remain permitted for server-to-server and CLI checks.

If multiple frontend origins are intentionally deployed, use one canonical origin or update the server's origin allowlist deliberately.

## 8. Production testing

Run:

```powershell
cd backend
npm run check
npm audit
npm start
curl.exe -i https://<backend-host>/api/health
curl.exe -i https://<backend-host>/api/test-supabase
curl.exe -i https://<backend-host>/api/videos
```

Browser test matrix:

- Homepage and all major pages at desktop and mobile widths.
- Registration, login, logout, password reset, and email confirmation.
- Regular-user denial of every `/api/admin/*` route.
- Admin pets, shelters, applications, appointments, vaccinations, support, and video CRUD.
- Adoption submission, unavailable-pet rejection, duplicate application rejection.
- Appointment future-date validation, shelter validation, conflict rejection, and successful save.
- Public catalog reads and RLS.
- YouTube iframe initialization and playback; any YouTube error code must show a fallback link.
- Uploaded video playback with signed/private bucket URLs.
- Browser console and network request failures.
- Cross-origin API requests after setting CORS and frontend URL.

## 9. Final deployment checklist

- [ ] Back up the Supabase project
- [ ] Apply migrations in order
- [ ] Verify tables, RLS, storage bucket, and bucket policies
- [ ] Rotate the Supabase service-role key if it was previously exposed
- [ ] Configure backend production environment variables
- [ ] Configure frontend public Supabase values and backend URL
- [ ] Configure Supabase Auth redirect URLs
- [ ] Enable email confirmation
- [ ] Run `npm run check` and `npm audit`
- [ ] Test health and Supabase endpoints
- [ ] Test auth and admin routes with dedicated accounts
- [ ] Test adoption and appointment workflows
- [ ] Test YouTube and uploaded-video playback on HTTPS
- [ ] Test desktop and mobile layouts
- [ ] Review CORS and browser console
- [ ] Commit and tag only after approval
