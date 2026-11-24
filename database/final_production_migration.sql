-- ============================================================
-- PetCare Connect final production database migration
-- ============================================================
-- Run this only after database/schema.sql (or an equivalent existing
-- PetCare Connect base schema) has been applied.
--
-- This script:
-- * does not delete or update existing application, pet, user, or video records;
-- * preserves existing tables and data;
-- * keeps RLS enabled;
-- * creates or reconciles only the known PetCare Connect objects;
-- * is safe to rerun.
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- Prerequisite checks
-- ----------------------------------------------------------------

DO $$
BEGIN
  IF to_regclass('public.users') IS NULL
     OR to_regclass('public.pets') IS NULL
     OR to_regclass('public.vaccination_records') IS NULL THEN
    RAISE EXCEPTION
      'Required PetCare Connect tables public.users, public.pets, and public.vaccination_records are missing. Apply database/schema.sql or the equivalent base schema first.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name IN ('role', 'status')
    GROUP BY table_name
    HAVING COUNT(*) = 2
  ) THEN
    RAISE EXCEPTION
      'public.users must contain role and status columns. Review the existing schema before continuing.';
  END IF;
END;
$$;

-- ----------------------------------------------------------------
-- Ensure public pet listings are available through RLS
-- ----------------------------------------------------------------

ALTER TABLE public.pets
  ADD COLUMN IF NOT EXISTS is_listed BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE public.pets ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'pets'
      AND policyname = 'Public read pets'
  ) THEN
    ALTER POLICY "Public read pets"
      ON public.pets
      USING (is_listed = TRUE);
  ELSE
    CREATE POLICY "Public read pets"
      ON public.pets
      FOR SELECT
      TO anon, authenticated
      USING (is_listed = TRUE);
  END IF;
END;
$$;

-- ----------------------------------------------------------------
-- Active-account helper function
-- ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_active_user()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = auth.uid()
      AND status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION public.is_active_user() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_active_user() TO authenticated;

-- ----------------------------------------------------------------
-- Active-account and listed-vaccination RLS policies
-- ----------------------------------------------------------------

DO $$
DECLARE
  policy_spec RECORD;
  policy_sql TEXT;
BEGIN
  FOR policy_spec IN
    SELECT *
    FROM (VALUES
      ('vaccination_records', 'Public read vaccination_records', 'SELECT',
        'EXISTS (SELECT 1 FROM public.pets p WHERE p.id = pet_id AND p.is_listed = true)', NULL),
      ('users', 'Users read own profile', 'SELECT',
        'auth.uid() = id AND public.is_active_user()', NULL),
      ('users', 'Users update own profile', 'UPDATE',
        'auth.uid() = id AND public.is_active_user()',
        'auth.uid() = id AND role = ''user'' AND status = ''active'''),
      ('users', 'Users insert own profile', 'INSERT', NULL,
        'auth.uid() = id AND role = ''user'' AND status = ''active'''),
      ('saved_pets', 'Users manage saved pets', 'ALL',
        'auth.uid() = user_id AND public.is_active_user()',
        'auth.uid() = user_id AND public.is_active_user()'),
      ('adoption_applications', 'Users read own applications', 'SELECT',
        'auth.uid() = user_id AND public.is_active_user()', NULL),
      ('adoption_applications', 'Users insert applications', 'INSERT', NULL,
        'auth.uid() = user_id AND public.is_active_user()'),
      ('appointments', 'Users manage own appointments', 'ALL',
        'auth.uid() = user_id AND public.is_active_user()',
        'auth.uid() = user_id AND public.is_active_user()'),
      ('notifications', 'Users read own notifications', 'SELECT',
        'auth.uid() = user_id AND public.is_active_user()', NULL),
      ('notifications', 'Users update own notifications', 'UPDATE',
        'auth.uid() = user_id AND public.is_active_user()',
        'auth.uid() = user_id AND public.is_active_user()'),
      ('reviews', 'Users insert reviews', 'INSERT', NULL,
        'auth.uid() = user_id AND public.is_active_user()'),
      ('support_conversations', 'Users read own support conversations', 'SELECT',
        'auth.uid() = user_id AND public.is_active_user()', NULL),
      ('support_conversations', 'Users create own support conversations', 'INSERT',
        NULL, 'auth.uid() = user_id AND public.is_active_user()'),
      ('support_messages', 'Users read messages in own support conversations', 'SELECT',
        'public.is_active_user() AND EXISTS (SELECT 1 FROM public.support_conversations c WHERE c.id = conversation_id AND c.user_id = auth.uid())',
        NULL),
      ('support_messages', 'Users send messages in own support conversations', 'INSERT',
        NULL,
        'public.is_active_user() AND sender_id = auth.uid() AND sender_role = ''user'' AND EXISTS (SELECT 1 FROM public.support_conversations c WHERE c.id = conversation_id AND c.user_id = auth.uid())')
    ) AS policies(table_name, policy_name, command, using_expression, check_expression)
  LOOP
    IF to_regclass(format('public.%I', policy_spec.table_name)) IS NULL THEN
      CONTINUE;
    END IF;

    EXECUTE format(
      'ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',
      policy_spec.table_name
    );

    IF EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = policy_spec.table_name
        AND policyname = policy_spec.policy_name
    ) THEN
      policy_sql := format(
        'ALTER POLICY %I ON public.%I',
        policy_spec.policy_name,
        policy_spec.table_name
      );
    ELSE
      policy_sql := format(
        'CREATE POLICY %I ON public.%I FOR %s',
        policy_spec.policy_name,
        policy_spec.table_name,
        policy_spec.command
      );
    END IF;

    IF policy_spec.using_expression IS NOT NULL THEN
      policy_sql := policy_sql
        || format(' USING (%s)', policy_spec.using_expression);
    END IF;

    IF policy_spec.check_expression IS NOT NULL THEN
      policy_sql := policy_sql
        || format(' WITH CHECK (%s)', policy_spec.check_expression);
    END IF;

    EXECUTE policy_sql;
  END LOOP;
END;
$$;

-- ----------------------------------------------------------------
-- Pet-care video catalog table
-- ----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.pet_care_videos (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  title         TEXT        NOT NULL,
  description   TEXT,
  category      TEXT        NOT NULL
                            CHECK (category IN (
                              'Dog Care',
                              'Cat Care',
                              'Pet Nutrition',
                              'Pet Training',
                              'Pet Health',
                              'Vaccination Awareness'
                            )),
  video_url     TEXT        NOT NULL,
  thumbnail_url TEXT,
  is_public     BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.pet_care_videos
  ADD COLUMN IF NOT EXISTS description TEXT;

ALTER TABLE public.pet_care_videos
  ADD COLUMN IF NOT EXISTS thumbnail_url TEXT;

ALTER TABLE public.pet_care_videos
  ADD COLUMN IF NOT EXISTS is_public BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE public.pet_care_videos
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

DO $$
DECLARE
  missing_columns TEXT;
BEGIN
  SELECT string_agg(required.column_name, ', ')
    INTO missing_columns
  FROM (
    VALUES ('id'), ('title'), ('description'), ('category'),
      ('video_url'), ('thumbnail_url'), ('created_at'), ('is_public')
  ) AS required(column_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pet_care_videos'
      AND column_name = required.column_name
  );

  IF missing_columns IS NOT NULL THEN
    RAISE EXCEPTION
      'public.pet_care_videos is missing required columns (%); review the existing table before continuing.',
      missing_columns;
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS pet_care_videos_public_category_created_idx
  ON public.pet_care_videos (category, created_at DESC)
  WHERE is_public = TRUE;

ALTER TABLE public.pet_care_videos ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.pet_care_videos TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.pet_care_videos TO authenticated;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'pet_care_videos'
      AND policyname = 'Public can read public pet-care videos'
  ) THEN
    ALTER POLICY "Public can read public pet-care videos"
      ON public.pet_care_videos
      USING (is_public = TRUE);
  ELSE
    CREATE POLICY "Public can read public pet-care videos"
      ON public.pet_care_videos
      FOR SELECT
      TO anon, authenticated
      USING (is_public = TRUE);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'pet_care_videos'
      AND policyname = 'Active admins can manage pet-care videos'
  ) THEN
    ALTER POLICY "Active admins can manage pet-care videos"
      ON public.pet_care_videos
      USING (
        EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  ELSE
    CREATE POLICY "Active admins can manage pet-care videos"
      ON public.pet_care_videos
      FOR ALL
      TO authenticated
      USING (
        EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  END IF;
END;
$$;

-- ----------------------------------------------------------------
-- Private pet-care-videos Storage bucket
-- ----------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'pet-care-videos'
  ) THEN
    INSERT INTO storage.buckets (
      id,
      name,
      public,
      file_size_limit,
      allowed_mime_types
    )
    VALUES (
      'pet-care-videos',
      'pet-care-videos',
      FALSE,
      104857600,
      ARRAY[
        'video/mp4',
        'video/webm',
        'video/quicktime',
        'image/jpeg',
        'image/png',
        'image/webp'
      ]
    );
  ELSE
    UPDATE storage.buckets
    SET
      public = FALSE,
      file_size_limit = 104857600,
      allowed_mime_types = ARRAY[
        'video/mp4',
        'video/webm',
        'video/quicktime',
        'image/jpeg',
        'image/png',
        'image/webp'
      ]
    WHERE id = 'pet-care-videos';
  END IF;
END;
$$;

-- ----------------------------------------------------------------
-- Storage object policies
-- ----------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Public can read published pet-care video files'
  ) THEN
    ALTER POLICY "Public can read published pet-care video files"
      ON storage.objects
      USING (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.pet_care_videos AS video
          WHERE video.is_public = TRUE
            AND (video.video_url = name OR video.thumbnail_url = name)
        )
      );
  ELSE
    CREATE POLICY "Public can read published pet-care video files"
      ON storage.objects
      FOR SELECT
      TO anon, authenticated
      USING (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.pet_care_videos AS video
          WHERE video.is_public = TRUE
            AND (video.video_url = name OR video.thumbnail_url = name)
        )
      );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Active admins can upload pet-care video files'
  ) THEN
    ALTER POLICY "Active admins can upload pet-care video files"
      ON storage.objects
      WITH CHECK (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  ELSE
    CREATE POLICY "Active admins can upload pet-care video files"
      ON storage.objects
      FOR INSERT
      TO authenticated
      WITH CHECK (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Active admins can update pet-care video files'
  ) THEN
    ALTER POLICY "Active admins can update pet-care video files"
      ON storage.objects
      USING (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      )
      WITH CHECK (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  ELSE
    CREATE POLICY "Active admins can update pet-care video files"
      ON storage.objects
      FOR UPDATE
      TO authenticated
      USING (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      )
      WITH CHECK (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Active admins can delete pet-care video files'
  ) THEN
    ALTER POLICY "Active admins can delete pet-care video files"
      ON storage.objects
      USING (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  ELSE
    CREATE POLICY "Active admins can delete pet-care video files"
      ON storage.objects
      FOR DELETE
      TO authenticated
      USING (
        bucket_id = 'pet-care-videos'
        AND EXISTS (
          SELECT 1
          FROM public.users AS profile
          WHERE profile.id = (SELECT auth.uid())
            AND profile.role = 'admin'
            AND profile.status = 'active'
        )
      );
  END IF;
END;
$$;

COMMIT;

-- ----------------------------------------------------------------
-- Verification queries (read-only)
-- ----------------------------------------------------------------

SELECT
  'pet_care_videos' AS object_name,
  to_regclass('public.pet_care_videos') IS NOT NULL AS exists
UNION ALL
SELECT
  'is_active_user',
  to_regprocedure('public.is_active_user()') IS NOT NULL
UNION ALL
SELECT
  'private pet-care-videos bucket',
  EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'pet-care-videos'
      AND public = FALSE
  );

SELECT policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'pet_care_videos'
ORDER BY policyname;

SELECT policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'storage'
  AND tablename = 'objects'
  AND policyname LIKE '%pet-care video%'
ORDER BY policyname;
