
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgsodium" WITH SCHEMA "pgsodium";

CREATE EXTENSION IF NOT EXISTS "http" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

CREATE TYPE "public"."setorOrdem" AS ENUM (
    'setor',
    'ordem'
);

ALTER TYPE "public"."setorOrdem" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualiza_conversas"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Atualiza a tabela 'conversas', definindo a coluna 'webhook_id_ultima' com o ID do novo registro inserido em 'webhook'
    -- onde a 'id_api' em 'conversas' é igual a 'id_api_conversa' em 'webhook'
    UPDATE conversas
    SET webhook_id_ultima = NEW.id
    WHERE conversas.id_api = NEW.id_api_conversa;

    -- Retorna o registro inserido
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."atualiza_conversas"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualiza_informacoes_colab_user"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Atualiza o setor_nome com base no setor_id da linha inserida/atualizada
    IF NEW.setor_id IS NOT NULL THEN
        SELECT "Nome" INTO NEW.setor_nome FROM "Setores" WHERE id = NEW.setor_id;
    END IF;

    -- Atualiza o empresa_nome com base no id_empresa da linha inserida/atualizada
    IF NEW.id_empresa IS NOT NULL THEN
        SELECT "Nome" INTO NEW.empresa_nome FROM "Empresa" WHERE id = NEW.id_empresa;
    END IF;

    -- Retorna a linha alterada para efetivar a atualização
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."atualiza_informacoes_colab_user"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualiza_nome_contato_conversa"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Atualiza o nome_contato em conversas com base no nome do contato referenciado
    UPDATE conversas
    SET nome_contato = (SELECT nome FROM contatos WHERE id = NEW.ref_contatos)
    WHERE id = NEW.id;

    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."atualiza_nome_contato_conversa"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualiza_ref_empresa_conversa"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Busca o id_empresa da tabela 'conexoes' que corresponde à key_instancia da nova conversa inserida
    SELECT id_empresa INTO NEW.ref_empresa
    FROM conexoes
    WHERE instance_key = NEW.key_instancia;

    -- Se a conversa já tem um ref_empresa, não faz a atualização
    IF NEW.ref_empresa IS NOT NULL THEN
        -- Atualiza o campo ref_empresa com o id_empresa encontrado
        -- Nota: Como é um AFTER INSERT, precisamos fazer um UPDATE na tabela 'conversas'
        UPDATE conversas
        SET ref_empresa = NEW.ref_empresa
        WHERE id = NEW.id;
    END IF;

    RETURN NEW;
END;
$$;

