
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

ALTER FUNCTION "public"."atualiza_ref_empresa_conversa"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualiza_setores_nomes"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF TG_OP = 'DELETE' AND NOT EXISTS (
        SELECT 1 FROM public.setores_users WHERE colab_id = OLD.colab_id
    ) THEN
        -- Se um DELETE ocorre e não há mais setores, limpa setores_nomes
        UPDATE public.colab_user SET setores_nomes = NULL WHERE auth_id = OLD.colab_id;
    ELSE
        -- Atualiza setores_nomes baseado nos setores existentes
        UPDATE public.colab_user cu
        SET setores_nomes = subquery.setores_nomes
        FROM (
            SELECT colab_id, array_agg(s."Nome") AS setores_nomes
            FROM public.setores_users su
            JOIN public."Setores" s ON su.setor_id = s.id
            WHERE su.colab_id = CASE
                WHEN TG_OP = 'DELETE' THEN OLD.colab_id
                ELSE NEW.colab_id
            END
            GROUP BY colab_id
        ) AS subquery
        WHERE cu.auth_id = subquery.colab_id;
    END IF;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."atualiza_setores_nomes"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualiza_ultima_mensagem_conversa"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Assume-se que NEW se refere à inserção ou atualização na tabela webhook.
    -- Verifica se este webhook é o mais recente para a conversa relacionada.
    IF (SELECT webhook_id_ultima FROM public.conversas WHERE id_api = NEW.id_api_conversa) = NEW.id THEN
        -- Determina o tipo de conteúdo e prepara o texto da última mensagem.
        DECLARE mensagem_texto TEXT;
        BEGIN
            IF NEW."áudio" IS NOT NULL THEN
                mensagem_texto := '🎙áudio';
            ELSIF NEW.imagem IS NOT NULL THEN
                mensagem_texto := '📷imagem';
            ELSIF NEW.video IS NOT NULL THEN
                mensagem_texto := '🎥vídeo';
            ELSIF NEW.file IS NOT NULL THEN
                mensagem_texto := '📄documento';
            ELSE
                mensagem_texto := COALESCE(NEW.mensagem, 'vazio');
            END IF;

            -- Atualiza a ultima_mensagem na tabela conversas.
            UPDATE public.conversas
            SET ultima_mensagem = mensagem_texto,
                atualizado = NEW."Lida",
                horario_ultima_mensagem = NEW.created_at -- Atualiza também o horário da última mensagem.
            WHERE id_api = NEW.id_api_conversa;

            RETURN NEW;
        END;
    END IF;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."atualiza_ultima_mensagem_conversa"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualizar_chat"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    jsonData JSONB;
BEGIN

    -- Se 'data' for NULL, retorna NEW sem fazer nada
IF NEW.data IS NULL THEN
  RETURN NEW;
END IF;

    -- Obtém o JSON da coluna "data"
    jsonData := NEW.data;

    -- Atualiza a coluna "contatos" com os números antes do "@" em "remoteJid"
    NEW.contatos := regexp_replace(jsondata->>'remoteJid', '(@[^@]*)$', '');

    -- Atualiza a coluna "fromMe" com o valor de "fromMe" (se existir)
    IF jsonb_exists(jsonData, 'fromMe') THEN
        NEW.fromMe := (jsondata->>'fromMe')::BOOLEAN;
    END IF;

    -- Atualiza a coluna "mensagem" com o valor de "conversation"
    NEW.mensagem := jsondata->>'conversation';

    -- Atualiza a coluna "áudio" com o conteúdo da variável "url" em "audioMessage" (se existir)
    IF jsonb_exists(jsondata, 'audioMessage') THEN
        NEW."áudio" := jsondata->'audioMessage'->>'url';
    END IF;

    -- Atualiza a coluna "imagem" com o conteúdo da variável "url" em "imageMessage" (se existir)
    IF jsonb_exists(jsondata, 'imageMessage') THEN
        NEW.imagem := jsondata->'imageMessage'->>'url';
        -- Atualiza a coluna "legenda imagem" com o conteúdo da variável "caption" (se existir)
        IF jsonb_exists(jsondata->'imageMessage', 'caption') THEN
            NEW."legenda imagem" := jsondata->'imageMessage'->>'caption';
        END IF;
    END IF;

    -- Atualiza a coluna "file" com o conteúdo da variável "url" em "documentMessage" (se existir)
    IF jsonb_exists(jsondata, 'documentMessage') THEN
        NEW.file := jsondata->'documentMessage'->>'url';
        -- Atualiza a coluna "legenda file" com o conteúdo da variável "caption" (se existir)
        IF jsonb_exists(jsondata->'documentMessage', 'caption') THEN
            NEW."legenda file" := jsondata->'documentMessage'->>'caption';
        END IF;
    END IF;

    NEW.id_api_conversa := jsondata->'key'->>'conversaId';

    RETURN NEW;
END;
$_$;

ALTER FUNCTION "public"."atualizar_chat"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualizar_nome_contato"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Atualiza todas as conversas relacionadas ao contato que foi alterado
    UPDATE conversas
    SET nome_contato = NEW.nome,
        foto_contato = NEW.foto -- Adicionando esta linha para atualizar a foto
    WHERE ref_contatos = NEW.id;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."atualizar_nome_contato"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."atualizar_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $_$DECLARE
    jsonData JSONB;
BEGIN

    -- Se 'data' for NULL, retorna NEW sem fazer nada
IF NEW.data IS NULL THEN
  RETURN NEW;
END IF;

    -- Obtém o JSON da coluna "data"
    jsonData := NEW.data;
   
    -- Retorna imediatamente se fromMe é true
    IF jsonData->'key'->>'fromMe' = 'true' THEN
      RETURN NEW;
    END IF;
    
    -- Atualiza a coluna "contatos" com os números antes do "@" em "remoteJid"
    NEW.contatos := regexp_replace(jsondata->>'remoteJid', '(@[^@]*)$', '');

    -- Atualiza a coluna "fromMe" com o valor de "fromMe" (se existir)
    IF jsonb_exists(jsonData, 'fromMe') THEN
        NEW.fromMe := (jsondata->>'fromMe')::BOOLEAN;
    END IF;

    -- Atualiza a coluna "mensagem" com o valor de "conversation"
    NEW.mensagem := jsondata->>'conversation';

    -- Atualiza a coluna "áudio" com o conteúdo da variável "url" em "audioMessage" (se existir)
    IF jsonb_exists(jsondata, 'audioMessage') THEN
        NEW."áudio" := jsondata->'audioMessage'->>'url';
    END IF;

    -- Atualiza a coluna "imagem" com o conteúdo da variável "url" em "imageMessage" (se existir)
    IF jsonb_exists(jsondata, 'imageMessage') THEN
        NEW.imagem := jsondata->'imageMessage'->>'url';
        -- Atualiza a coluna "legenda imagem" com o conteúdo da variável "caption" (se existir)
        IF jsonb_exists(jsondata->'imageMessage', 'caption') THEN
            NEW."legenda imagem" := jsondata->'imageMessage'->>'caption';
        END IF;
    END IF;

    -- Atualiza a coluna "file" com o conteúdo da variável "url" em "documentMessage" (se existir)
    IF jsonb_exists(jsondata, 'documentMessage') THEN
        NEW.file := jsondata->'documentMessage'->>'url';
        -- Atualiza a coluna "legenda file" com o conteúdo da variável "caption" (se existir)
        IF jsonb_exists(jsondata->'documentMessage', 'caption') THEN
            NEW."legenda file" := jsondata->'documentMessage'->>'caption';
        END IF;
    END IF;

    -- Atualiza a coluna "id_api_conversa" com o valor de "conversaId"
  NEW.id_api_conversa := jsondata->'key'->>'conversaId';

    RETURN NEW;
END;$_$;

ALTER FUNCTION "public"."atualizar_webhook"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."busca_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" "text") RETURNS TABLE("id" bigint)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_lista_setores bigint[]; -- Variável para armazenar o array convertido
BEGIN
  -- Convertendo a string para um array de bigint
  v_lista_setores := string_to_array(p_lista_setores, ',')::bigint[];

  RETURN QUERY
  SELECT c.id
  FROM conversas c
  WHERE c."Status" = 'Espera'
    AND (c.id_setor = ANY(v_lista_setores))
    AND (
      (p_nome_contato IS NOT NULL AND p_nome_contato <> '' AND c.nome_contato ILIKE '%' || p_nome_contato || '%')
      OR (
        (p_nome_contato IS NULL OR p_nome_contato = '')
        AND (
          (p_istransferida AND c.istransferida = true)
          OR (p_isforahorario AND c.isforahorario = true)
          OR (p_isespera AND c.isespera = true)
        )
      )
    );
END;
$$;

ALTER FUNCTION "public"."busca_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_atalho_resposta_rapida"("termo_pesquisa" "text") RETURNS TABLE("atalhoresposta" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT "Respostas_Rapidas"."Atalho" AS AtalhoResposta
    FROM "Respostas_Rapidas" 
    WHERE "Respostas_Rapidas"."Atalho" ILIKE CONCAT('%', termo_pesquisa, '%');
END;
$$;

ALTER FUNCTION "public"."buscar_atalho_resposta_rapida"("termo_pesquisa" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text") RETURNS TABLE("atalhoresposta" "text", "textoresposta" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT "Respostas_Rapidas"."Atalho" AS AtalhoResposta, "Respostas_Rapidas"."Texto" AS TextoResposta
    FROM "Respostas_Rapidas" 
    WHERE "Respostas_Rapidas"."Atalho" ILIKE CONCAT('%', termo_pesquisa, '%');
END;
$$;

ALTER FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text", "ref_empresa" integer) RETURNS TABLE("atalhoresposta" "text", "textoresposta" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT "Respostas_Rapidas"."Atalho" AS AtalhoResposta, "Respostas_Rapidas"."Texto" AS TextoResposta
    FROM "Respostas_Rapidas" 
    WHERE "Respostas_Rapidas"."Atalho" ILIKE CONCAT('%', termo_pesquisa, '%')
    AND "Respostas_Rapidas"."id_empresa" = ref_empresa;
END;
$$;

ALTER FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text", "ref_empresa" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    conversas_array json[] := '{}';
    conversa_json json;
    webhooks_json json;
    resultado_final json;
    limite int := 2;
BEGIN
    -- Obtendo todas as conversas e seus respectivos webhooks com subconsulta
    FOR conversa_json, webhooks_json IN
        SELECT 
            row_to_json(subquery.*),
            (SELECT json_agg(webhook ORDER BY webhook.created_at ASC) FROM webhook WHERE webhook.id_api_conversa = subquery.id_api)
        FROM 
            (SELECT * FROM conversas
             WHERE conversas.ref_contatos = refContatosId AND 
                   conversas.ref_empresa = refEmpresaId AND
                   conversas.isdeleted_conversas = FALSE
             ORDER BY conversas.created_at DESC
             LIMIT limite OFFSET (pagina - 1) * limite) AS subquery
        ORDER BY 
             subquery.created_at ASC
    LOOP
        conversas_array := array_append(conversas_array, json_build_object(
            'conversa', conversa_json,
            'webhooks', webhooks_json
        ));
    END LOOP;

    resultado_final := json_build_object('results', array_to_json(conversas_array));
    
    RETURN resultado_final;
END;
$$;

ALTER FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer, "instanciaparam" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    conversas_array json[] := '{}';
    conversa_json json;
    webhooks_json json;
    resultado_final json;
    limite int := 2;
BEGIN
    -- Obtendo todas as conversas e seus respectivos webhooks com subconsulta
    FOR conversa_json, webhooks_json IN
        SELECT 
            row_to_json(subquery.*),
            (SELECT json_agg(json_build_object('data', data_webhook, 'webhooks', webhooks_dia))
             FROM (
                SELECT created_at::date as data_webhook, json_agg(webhook ORDER BY webhook.created_at ASC) as webhooks_dia
                FROM webhook
                WHERE webhook.id_api_conversa = subquery.id_api
                GROUP BY created_at::date
                ORDER BY created_at::date ASC
             ) sub)
        FROM 
            (SELECT * FROM conversas
             WHERE conversas.ref_contatos = refContatosId AND 
                   conversas.ref_empresa = refEmpresaId AND
                   conversas.key_instancia = instanciaParam AND
                   conversas.isdeleted_conversas = FALSE
             ORDER BY conversas.created_at DESC
             LIMIT limite OFFSET (pagina - 1) * limite) AS subquery
        ORDER BY 
             subquery.created_at ASC
    LOOP
        conversas_array := array_append(conversas_array, json_build_object(
            'conversa', conversa_json,
            'webhooks', webhooks_json
        ));
    END LOOP;

    resultado_final := json_build_object('results', array_to_json(conversas_array));
    
    RETURN resultado_final;
END;
$$;

ALTER FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer, "instanciaparam" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean) RETURNS TABLE("id" bigint)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT c.id
    FROM conversas c
    WHERE ("Status" = 'Espera')
      AND (p_nome_contato IS NULL OR p_nome_contato = '' OR nome_contato ILIKE '%' || p_nome_contato || '%')
      AND istransferida = p_istransferida
      AND isforahorario = p_isforahorario
      AND isespera = p_isespera;
END;
$$;

ALTER FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" bigint[]) RETURNS TABLE("id" bigint)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT c.id
    FROM conversas c
    WHERE ("Status" = 'Espera')
      AND (p_nome_contato IS NULL OR p_nome_contato = '' OR nome_contato ILIKE '%' || p_nome_contato || '%')
      AND (c.id_setor = ANY(p_lista_setores))
      AND (istransferida = p_istransferida OR isforahorario = p_isforahorario OR isespera = p_isespera);
END;
$$;

ALTER FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" bigint[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text") RETURNS TABLE("nome" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT "conexoes"."Nome"
    FROM "conexoes" 
    WHERE "conexoes"."Nome" ILIKE CONCAT('%', termo_pesquisa, '%');
END;
$$;

ALTER FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";

CREATE TABLE IF NOT EXISTS "public"."conexoes" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Nome" "text",
    "Número" "text",
    "Empresa" "text",
    "Plataforma" "text",
    "Status" boolean DEFAULT false,
    " Setor_Principal" bigint,
    "Conexão_Principal" boolean DEFAULT true,
    "instance_key" "text",
    "id_empresa" bigint DEFAULT '1'::bigint NOT NULL,
    "user" bigint,
    "qrcode" "text",
    "status_conexao" "text",
    "isConexaoRetorno" boolean DEFAULT false,
    "id_contato_retorno" bigint,
    "mensagemRetorno" "text"
);

ALTER TABLE "public"."conexoes" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text", "qref_empresa" integer) RETURNS SETOF "public"."conexoes"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT *
    FROM conexoes
    WHERE conexoes."Nome" ILIKE CONCAT('%', termo_pesquisa, '%')
      AND conexoes.id_empresa = qref_empresa;
END;
$$;

ALTER FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text", "qref_empresa" integer) OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."contatos" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nome" "text",
    "numero" character varying,
    "email" character varying,
    "foto" "text",
    "authid" "uuid",
    "instagram" "text",
    "profissão" "text",
    "ref_conversa" bigint,
    "conversa_ativa" boolean DEFAULT false,
    "ref_empresa" bigint,
    "status_conversa" "text" DEFAULT 'Bot'::"text",
    "isdeleted_contatos" boolean DEFAULT false,
    "numero_relatorios" "text",
    "isconexao" boolean DEFAULT false
);

ALTER TABLE "public"."contatos" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text") RETURNS SETOF "public"."contatos"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT contatos.*
    FROM contatos 
    WHERE contatos.nome ILIKE CONCAT('%', termo_pesquisa, '%');
END;
$$;

ALTER FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text", "qref_empresa" integer) RETURNS SETOF "public"."contatos"
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
    RETURN QUERY 
    SELECT *
    FROM contatos 
    WHERE 
        contatos.ref_empresa = qref_empresa
        AND contatos.isdeleted_contatos = FALSE
        AND (
            (termo_pesquisa ~ '^[0-9]+$' AND contatos.numero ILIKE CONCAT('%', termo_pesquisa, '%'))
            OR
            (termo_pesquisa ~ '^[^0-9]+$' AND contatos.nome ILIKE CONCAT('%', termo_pesquisa, '%'))
        );
END;
$_$;

ALTER FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text", "qref_empresa" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text") RETURNS SETOF "public"."contatos"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT contatos.*
    FROM contatos 
    WHERE contatos.nome ILIKE CONCAT('%', termo_pesquisa, '%')
    AND contatos.conversa_ativa = FALSE;
END;
$$;

ALTER FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text", "qref_empresa" integer) RETURNS SETOF "public"."contatos"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT contatos.*
    FROM contatos 
    WHERE contatos.nome ILIKE CONCAT('%', termo_pesquisa, '%')
    AND contatos.conversa_ativa = FALSE
    AND contatos.ref_empresa = qref_empresa;
END;
$$;

ALTER FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text", "qref_empresa" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_setores_conexao_selecionados"("id_emp" bigint, "id_conn" bigint) RETURNS TABLE("id" bigint, "nome" "text", "selecionado" boolean)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT s.id, s."Nome",
           EXISTS(SELECT 1 FROM public.setor_conexao sc WHERE sc.id_setor = s.id AND sc.id_conexao = id_conn) AS selecionado
    FROM public."Setores" s
    WHERE s.id_empresas = id_emp AND s.isdeleted_setor = false;
END;
$$;

ALTER FUNCTION "public"."buscar_setores_conexao_selecionados"("id_emp" bigint, "id_conn" bigint) OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."colab_user" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "profile_picture" "text",
    "username" character varying,
    "auth_id" "uuid",
    "data_nascimento" "text",
    "contato" "text",
    "genero" "text",
    "setor_id" bigint,
    "email" "text",
    "Cargo" "text",
    "ativo" boolean DEFAULT true,
    "Tipo" "text",
    "online" boolean DEFAULT false,
    "numero_conversas" numeric,
    "numero_tranferencias" numeric,
    "numero_espera" numeric,
    "id_empresa" bigint DEFAULT '1'::bigint NOT NULL,
    "key_colabuser" "text",
    "empresa_nome" "text",
    "setor_conexao_propria" boolean DEFAULT false,
    "setor_nome" "text",
    "isdeleted_colabuser" boolean DEFAULT false,
    "setores" "public"."setorOrdem"[],
    "contaValidada" boolean DEFAULT false,
    "setores_nomes" "text"[]
);

ALTER TABLE "public"."colab_user" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_username"("termo_pesquisa" "text") RETURNS SETOF "public"."colab_user"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT colab_user.*
    FROM colab_user 
    WHERE colab_user.username ILIKE '%' || termo_pesquisa || '%';
END;
$$;

ALTER FUNCTION "public"."buscar_username"("termo_pesquisa" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_username"("termo_pesquisa" "text", "qref_empresa" integer) RETURNS SETOF "public"."colab_user"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT colab_user.*
    FROM colab_user 
    WHERE colab_user.username ILIKE '%' || termo_pesquisa || '%'
      AND colab_user.id_empresa = qref_empresa;
END;
$$;

ALTER FUNCTION "public"."buscar_username"("termo_pesquisa" "text", "qref_empresa" integer) OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."webhook" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data" "jsonb",
    "contatos" "text",
    "fromMe" boolean,
    "mensagem" "text",
    "áudio" "text",
    "imagem" "text",
    "legenda imagem" "text",
    "file" "text",
    "legenda file" "text",
    "id_grupo" bigint,
    "deletada" boolean DEFAULT false,
    "chatfire" boolean DEFAULT false,
    "Lida" boolean DEFAULT false,
    "id_api_conversa" "text",
    "is_edge_function_insert" boolean DEFAULT false NOT NULL,
    "video" "text",
    "id_contato_webhook" bigint,
    "replyWebhook" bigint,
    "idMensagem" "text",
    "instance_key" "text"
);

ALTER TABLE "public"."webhook" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscar_webhooks"("limite" integer, "qid_api_conversa" "text") RETURNS SETOF "public"."webhook"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY 
    SELECT w.*
    FROM webhook w
    WHERE w.id_api_conversa = Qid_api_conversa
    ORDER BY w.created_at 
    LIMIT limite;
END;
$$;

ALTER FUNCTION "public"."buscar_webhooks"("limite" integer, "qid_api_conversa" "text") OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."Bot" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id_empresa" bigint DEFAULT '1'::bigint NOT NULL,
    "imagem" "text",
    "msg_inicio" "text" DEFAULT 'Oi *{{nome_cliente}}*!     Eu sou a 🙋🏽 *Bela*, assistente virtual da Blz Sistemas.    🔢 Para iniciar seu atendimento digite número da opção desejada:'::"text",
    "msg_fila" "text" DEFAULT '✅ protocolo de atendimento: *{{protocolo}}*.  Olá *{{nome_cliente}}* já estou lhe encaminhando para um dos nossos atendentes.   Para agilizar seu atendimento por favor, digite sua dúvida:'::"text",
    "msg_assumir" "text" DEFAULT '{{emoji_sexo_atendente}} *{{nome_atendente}}*: {{saudacao}} *{{nome_cliente}}*, tudo bem?'::"text",
    "msg_finalizar" "text" DEFAULT '😃 Agradecemos o seu contato!   Pedimos por gentileza que não responda essa mensagem, pois esse atendimento foi concluído e qualquer nova mensagem abrirá novo atendimento.   Mas lembramos que estamos aqui para qualquer nova necessidade.  Conte com a gente!  ✅ Segue seu protocolo: *{{protocolo}}*.'::"text",
    "setor_inatividade" bigint,
    "setor_horario_fora" bigint,
    "ativo" boolean DEFAULT false,
    "msg_botFora" "text" DEFAULT 'Caro cliente, nosso horário de funcionamento é de Segunda à Sexta-feira das 08h às 19h e aos Sábados das 8h às 13h.   Favor aguardar nosso retorno dentro do nosso horário de atendimento 😉.'::"text",
    "tempo_transferencia" bigint DEFAULT '1'::bigint,
    "key_conexão" "text",
    "funcionamento" "jsonb" DEFAULT '{"dias": {"1": {"fim": "23:00", "ativo": true, "inicio": "00:00"}, "2": {"fim": "23:00", "ativo": true, "inicio": "00:00"}, "3": {"fim": "23:00", "ativo": true, "inicio": "00:00"}, "4": {"fim": "23:00", "ativo": true, "inicio": "00:00"}, "5": {"fim": "23:00", "ativo": true, "inicio": "00:00"}, "6": {"fim": "23:00", "ativo": true, "inicio": "00:00"}, "7": {"fim": "23:00", "ativo": true, "inicio": "00:00"}}}'::"jsonb" NOT NULL,
    "setoresEscolhidos" "jsonb"[],
    "setor_transferido_automaticamente" bigint,
    "horarios_costumizados" boolean DEFAULT false,
    "tempo_retorno" bigint
);

ALTER TABLE "public"."Bot" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."buscarbotporempresa"("refempresa" integer) RETURNS SETOF "public"."Bot"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY SELECT * FROM "Bot" WHERE id_empresa = refEmpresa;
END;
$$;

ALTER FUNCTION "public"."buscarbotporempresa"("refempresa" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."contar_conexoes_por_empresa"("refempresa" integer) RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO total
    FROM conexoes
    WHERE "id_empresa" = refEmpresa;

    RETURN total;
END;
$$;

ALTER FUNCTION "public"."contar_conexoes_por_empresa"("refempresa" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."contar_setores_por_empresa"("refempresa" integer) RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO total
    FROM "Setores"
    WHERE "id_empresas" = refEmpresa;

    RETURN total;
END;
$$;

ALTER FUNCTION "public"."contar_setores_por_empresa"("refempresa" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."create_bot_for_new_company"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    INSERT INTO "Bot"(id_empresa)
    VALUES (NEW.id); -- Supondo que o nome da coluna de identificação em "Empresa" seja 'id'

    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."create_bot_for_new_company"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."extrair_contatos"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    registro JSONB;
    remote_jid_text TEXT;
BEGIN
    FOR registro IN (SELECT id, data FROM webhook) LOOP
        remote_jid_text := registro.data->'key'->>'remoteJid';
        UPDATE webhook
        SET contatos = substring(remote_jid_text FROM '^(.*?)@')
        WHERE id = registro.id;
    END LOOP;
END;
$$;

ALTER FUNCTION "public"."extrair_contatos"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."extrair_numeros"("input_text" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  resultado TEXT;
BEGIN
  SELECT substring(input_text FROM '^[0-9]+') INTO resultado;
  RETURN resultado;
  SELECT extrair_numeros("Número") FROM conexoes;
END;
$$;

ALTER FUNCTION "public"."extrair_numeros"("input_text" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_acessible_setor_conexao"("current_auth_id" "uuid") RETURNS TABLE("id" bigint, "created_at" timestamp with time zone, "id_setor" bigint, "id_conexao" bigint, "id_empresa" bigint, "keyConexao" "text", "nome_conexao" "text", "nome_setor" "text")
    LANGUAGE "plpgsql" STABLE
    AS $$
BEGIN
    RETURN QUERY
    SELECT sc.id, sc.created_at, sc.id_setor, sc.id_conexao, sc.id_empresa, sc."keyConexao", c."Nome", sc.nome_setor
    FROM public.setor_conexao sc
    JOIN public.setores_users su ON sc.id_setor = su.setor_id
    JOIN public.conexoes c ON sc.id_conexao = c.id
    WHERE su.colab_id = current_auth_id;
END;
$$;

ALTER FUNCTION "public"."get_acessible_setor_conexao"("current_auth_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_colab_user_by_auth_id"("p_auth_id" "uuid") RETURNS SETOF "public"."colab_user"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY SELECT * FROM colab_user WHERE auth_id = p_auth_id;
END;
$$;

ALTER FUNCTION "public"."get_colab_user_by_auth_id"("p_auth_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_contact_name_from_conversa"("conversa_id" integer) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    nome_result TEXT;
BEGIN
    SELECT nome INTO nome_result FROM contatos WHERE id = conversa_id;
    RETURN nome_result;
END;
$$;

ALTER FUNCTION "public"."get_contact_name_from_conversa"("conversa_id" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_conversas_with_contact_names"() RETURNS TABLE("id" bigint, "ref_message" bigint, "nome_contato" character varying, "messages_text" "text", "ref_colabuser" bigint, "ref_contatos" bigint, "authid" "uuid", "created_at" timestamp with time zone, "atualizado" boolean)
    LANGUAGE "sql"
    AS $$
  SELECT 
    conversas.id,
    conversas.ref_message,
    contatos.nome AS nome_contato,
    messages.text AS messages_text,
    conversas.ref_colabuser, 
    conversas.ref_contatos, 
    conversas.authid,
    conversas.created_at,
    conversas.atualizado
  FROM conversas
  JOIN contatos ON conversas.ref_contatos = contatos.id
  JOIN messages ON conversas.ref_message = messages.id;
$$;

ALTER FUNCTION "public"."get_conversas_with_contact_names"() OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."Empresa" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Nome" "text",
    "key" "text",
    "CPF" "text",
    "CNPJ" "text",
    "email" "text",
    "telefone" "text",
    "endereco_rua" "text",
    "endereco_numero" "text",
    "endereco_bairro" "text",
    "endereco_cidade" "text",
    "user_master" "uuid",
    "cep_endereco" "text",
    "assunto_obrigatorio" boolean DEFAULT false
);

ALTER TABLE "public"."Empresa" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_empresa_by_id"("id_empresa" bigint) RETURNS SETOF "public"."Empresa"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY SELECT * FROM public."Empresa" WHERE id = id_empresa;
END;
$$;

ALTER FUNCTION "public"."get_empresa_by_id"("id_empresa" bigint) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_nome_from_conversa"("conversa_id" integer) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    nome_result TEXT;
BEGIN
    SELECT nome INTO nome_result FROM contatos WHERE id = conversa_id;
    RETURN nome_result;
END;
$$;

ALTER FUNCTION "public"."get_nome_from_conversa"("conversa_id" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_setores_as_json"("id_empresa_ref" integer) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN (
        SELECT json_agg(row_to_json(t))
        FROM (
            SELECT "Nome" as nome, ordem, id AS setor, ativo_bot AS ativo
            FROM "Setores"
            WHERE id_empresas = id_empresa_ref
            ORDER BY ordem
        ) t
    );
END;
$$;

ALTER FUNCTION "public"."get_setores_as_json"("id_empresa_ref" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_user_setores"("apiauth_id" "uuid") RETURNS TABLE("setor_id" bigint, "nome_setor" "text", "key_conexao" "text", "ativo_bot" boolean)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.id,
        s."Nome",
        s.key_conexao,
        s.ativo_bot
    FROM
        public."Setores" s
    JOIN
        public.setores_users su ON s.id = su.setor_id
    WHERE
        su.colab_id = apiauth_id
        AND s.isdeleted_setor = FALSE; -- Considerando apenas setores não deletados
END;
$$;

ALTER FUNCTION "public"."get_user_setores"("apiauth_id" "uuid") OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."conversas" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ref_contatos" bigint,
    "authid" "uuid",
    "atualizado" boolean DEFAULT false,
    "nome_contato" "text",
    "foto_contato" "text",
    "arquivada" boolean DEFAULT false,
    "ultima_mensagem" "text" DEFAULT 'vazio'::"text",
    "horario_ultima_mensagem" timestamp with time zone DEFAULT "now"(),
    "Protocolo" "text" DEFAULT ("floor"(("random"() * (((10)::double precision ^ (8)::double precision) - ((10)::double precision ^ (7)::double precision)))) + ((10)::double precision ^ (7)::double precision)),
    "Status" "text" DEFAULT 'Bot'::"text",
    "numero_contato" "text" DEFAULT '999999999'::"text",
    "Setor_nomenclatura" "text",
    "colabuser_nome" "text",
    "hora_finalizada" timestamp with time zone,
    "ref_empresa" bigint,
    "empresa_nome" "text",
    "Encerramento_assunto" "text",
    "Encerramento_tag" "text",
    "Relato_conversa" "text",
    "observacao_transferencia" "text",
    "updated_at" timestamp with time zone,
    "webhook_id_ultima" bigint,
    "id_setor" bigint,
    "key_instancia" "text",
    "id_api" "text",
    "transferida_setor" bigint,
    "transferida_user" "uuid",
    "foto_colabUser" "text",
    "transferida_nome_user" "text",
    "transferida_nome_setor" character varying,
    "isdeleted_conversas" boolean DEFAULT false,
    "istransferida" boolean DEFAULT false,
    "isforahorario" boolean DEFAULT false,
    "isespera" boolean DEFAULT false,
    "fixa" boolean DEFAULT false,
    "conexao_nomenclatura" "text"
);

ALTER TABLE "public"."conversas" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."inatividade_check"() RETURNS SETOF "public"."conversas"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    conversa_row conversas;
    bot_row "Bot";
    tempo_transferencia_minutos INT;
    setor_row "Setores";
BEGIN
    FOR conversa_row IN SELECT * FROM conversas
    LOOP
        SELECT * INTO bot_row FROM "Bot" WHERE id_empresa = conversa_row.ref_empresa LIMIT 1;

        IF bot_row.ativo = false AND conversa_row."Status" = 'Bot' THEN
            SELECT * INTO setor_row FROM "Setores" WHERE id = bot_row.setor_inatividade LIMIT 1;
            UPDATE conversas
            SET "Status" = 'Em Atendimento', id_setor = bot_row.setor_inatividade
            WHERE id = conversa_row.id;
            
            SELECT "status", "content"::jsonb from http_post(concat('https://api.fireapi.com.br/message/text?key=', conversa_row.key_instancia), concat('{"id": "', conversa_row.numero_contato, '", "message": "Atendimento transferido para o setor ', setor_row.setor_nome, 'por inatividade do usuário"}'), 'application/x-www-form-urlencoded');
        END IF;

        tempo_transferencia_minutos := bot_row.tempo_transferencia;

        IF AGE(NOW(), conversa_row.horario_ultima_mensagem) > INTERVAL '1 minute' * tempo_transferencia_minutos AND conversa_row."Status" = 'Bot' THEN
            SELECT * INTO setor_row FROM "Setores" WHERE id = bot_row.setor_inatividade LIMIT 1;
            UPDATE conversas
            SET "Status" = 'Em Atendimento', id_setor = bot_row.setor_inatividade
            WHERE id = conversa_row.id;

            SELECT "status", "content"::jsonb from http_post(concat('https://api.fireapi.com.br/message/text?key=', conversa_row.key_instancia), concat('{"id": "', conversa_row.numero_contato, '", "message": "Atendimento transferido para o setor ', setor_row.setor_nome, 'por inatividade do usuário"}'), 'application/x-www-form-urlencoded');
        END IF;

        -- Retorne a linha da conversa
        RETURN NEXT conversa_row;
    END LOOP;

    -- Sinalize o fim do conjunto de resultados
    RETURN;
END $$;

ALTER FUNCTION "public"."inatividade_check"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."insere_contato_e_atualiza_conversa"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
    contato_existente_id INTEGER;
BEGIN
    -- Verifica se ref_empresa já está preenchida na nova conversa
    IF NEW.ref_empresa IS NULL THEN
        -- Se ref_empresa é NULL, termina a função sem fazer alterações
        RETURN NEW;
    END IF;

    -- Tenta adquirir um bloqueio no contato existente com o mesmo número e ref_empresa
    SELECT id INTO contato_existente_id FROM contatos
    WHERE numero = NEW.numero_contato AND ref_empresa = NEW.ref_empresa
    FOR UPDATE NOWAIT;

    -- Se não encontrar um contato existente, cria um novo
    IF contato_existente_id IS NULL THEN
        INSERT INTO contatos (numero, nome, conversa_ativa, ref_empresa, foto)
        VALUES (NEW.numero_contato, NEW.nome_contato, TRUE, NEW.ref_empresa, NEW.foto_contato)
        RETURNING id INTO contato_existente_id;
    END IF;

    -- Atualiza o registro em conversas com o ID do contato existente ou novo
    UPDATE conversas SET ref_contatos = contato_existente_id WHERE id = NEW.id;

    RETURN NEW;
END;$$;

ALTER FUNCTION "public"."insere_contato_e_atualiza_conversa"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."paginacao_contatos"("limite" integer, "qref_empresa" bigint) RETURNS SETOF "public"."contatos"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY SELECT * FROM contatos WHERE ref_empresa = Qref_empresa AND isdeleted_contatos = FALSE ORDER BY created_at LIMIT limite;
END;
$$;

ALTER FUNCTION "public"."paginacao_contatos"("limite" integer, "qref_empresa" bigint) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."process_chat_data"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  -- Retorna imediatamente se fromMe é true
  IF NEW.data->'key'->>'fromMe' = 'true' THEN
    RETURN NEW;
  END IF;
  
  -- Processa remoteJid
  IF NEW.data->>'remoteJid' IS NOT NULL THEN
    IF LENGTH(SPLIT_PART(NEW.data->>'remoteJid', '@', 1)) <= 11 THEN
      -- Atualiza contatos somente se está null
      IF NEW.contatos IS NULL THEN
        NEW.contatos := SPLIT_PART(NEW.data->>'remoteJid', '@', 1);
      END IF;
    ELSE
      -- Atualiza id_grupo somente se está null
      IF NEW.id_grupo IS NULL THEN
        NEW.id_grupo := SPLIT_PART(NEW.data->>'remoteJid', '@', 1);
      END IF;
    END IF;
  END IF;

  -- Processa fromMe
  IF NEW.data ? 'fromMe' AND NEW.data->>'fromMe' IS NOT NULL THEN
    IF NEW."fromMe" IS NULL THEN
      NEW."fromMe" := (NEW.data->>'fromMe')::boolean;
    END IF;
  END IF;

  -- Processa conversation
  IF NEW.data ? 'conversation' AND NEW.data->>'conversation' IS NOT NULL AND NEW.mensagem IS NULL THEN
    NEW.mensagem := NEW.data->>'conversation';
  END IF;

  -- Processa audioMessage
  IF NEW.data ? 'audioMessage' AND NEW.data->'audioMessage'->>'url' IS NOT NULL AND NEW."áudio" IS NULL THEN
    NEW."áudio" := NEW.data->'audioMessage'->>'url';
  END IF;

  -- Processa imageMessage
  IF NEW.data ? 'imageMessage' AND NEW.data->'imageMessage'->>'url' IS NOT NULL THEN
    -- Atualiza imagem somente se está null
    IF NEW.imagem IS NULL THEN
      NEW.imagem := NEW.data->'imageMessage'->>'url';
    END IF;
    -- Verifica a existência da legenda da imagem
    IF NEW.data->'imageMessage'->>'caption' IS NOT NULL AND NEW."legenda imagem" IS NULL THEN
      NEW."legenda imagem" := NEW.data->'imageMessage'->>'caption';
    END IF;
  END IF;

  -- Processa documentMessage
  IF NEW.data ? 'documentMessage' AND NEW.data->'documentMessage'->>'url' IS NOT NULL THEN
    -- Atualiza file somente se está null
    IF NEW.file IS NULL THEN
      NEW.file := NEW.data->'documentMessage'->>'url';
    END IF;
    -- Verifica a existência da legenda do arquivo
    IF NEW.data->'documentMessage'->>'caption' IS NOT NULL AND NEW."legenda file" IS NULL THEN
      NEW."legenda file" := NEW.data->'documentMessage'->>'caption';
    END IF;
  END IF;

  -- Processa conversaId
  IF NEW.data ? 'key' AND NEW.data->'key'->>'conversaId' IS NOT NULL AND NEW.id_api_conversa IS NULL THEN
    NEW.id_api_conversa := NEW.data->'key'->>'conversaId';
  END IF;

  RETURN NEW;
END;$$;

ALTER FUNCTION "public"."process_chat_data"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."process_webhook_data"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  cleaned_remoteJid text;
  Q record;
BEGIN

  IF NEW.data->'key'->>'fromMe' = 'true' THEN
    RETURN NEW;
  END IF;
  -- Processa remoteJid
  IF NEW.data->'key'->>'remoteJid' IS NOT NULL THEN
    cleaned_remoteJid := regexp_replace(NEW.data->'key'->>'remoteJid', '[^0-9]', '', 'g');
    IF LENGTH(cleaned_remoteJid) <= 13 THEN
      NEW.contatos := cleaned_remoteJid;
      -- Ligando com o conversas
      SELECT * INTO Q FROM conversas WHERE conversas.numero_contato = cleaned_remoteJid;
      Q.webhook_id_ultima := NEW.id;

      -- Processa fromMe
      IF NEW.data->'key'->>'fromMe' IS NOT NULL THEN
        NEW."fromMe" := (NEW.data->'key'->>'fromMe')::boolean;
      END IF;
    ELSE
      NEW.id_grupo := CAST(cleaned_remoteJid AS bigint);
       -- Processa fromMe (Sem a atualização de status)
      IF NEW.data->'key'->>'fromMe' IS NOT NULL THEN
        NEW."fromMe" := (NEW.data->'key'->>'fromMe')::boolean;
      END IF;
    END IF;
  END IF;

  -- Processa extendedTextMessage
  IF NEW.data->'message'->'extendedTextMessage' IS NOT NULL THEN
    NEW.mensagem := NEW.data->'message'->'extendedTextMessage'->>'text';
  END IF;

  -- Processa conversation
  IF NEW.data->'message'->>'conversation' IS NOT NULL THEN
    NEW.mensagem := NEW.data->'message'->>'conversation';
  END IF;

  -- -- Processa audioMessage
  IF NEW.data->'message'->'audioMessage' IS NOT NULL THEN
    NEW."áudio" := NEW.data->'message'->'audioMessage'->>'url';
  END IF;

  -- -- Processa reactionMessage
  IF NEW.data->'message'->'reactionMessage' IS NOT NULL THEN
    NEW.mensagem := NEW.data->'message'->'reactionMessage'->>'text';
  END IF;

  -- -- Processa imageMessage
  IF NEW.data->'message'->'imageMessage' IS NOT NULL THEN
    NEW.imagem := NEW.data->'message'->'imageMessage'->>'url';
    -- Verifica a existência da legenda da imagem
    IF NEW.data->'message'->'imageMessage'->>'caption' IS NOT NULL THEN
      NEW."legenda imagem" := NEW.data->'message'->'imageMessage'->>'caption';
    END IF;
  END IF;

  -- Processa documentMessage
  IF NEW.data->'message'->'documentMessage' IS NOT NULL THEN
    NEW.file := NEW.data->'message'->'documentMessage'->>'url';
    -- Verifica a existência da legenda do arquivo
    IF NEW.data->'message'->'documentMessage'->>'caption' IS NOT NULL THEN
      NEW."legenda file" := NEW.data->'message'->'documentMessage'->>'caption';
    END IF;
  END IF;  

  RETURN NEW;
END;$$;

ALTER FUNCTION "public"."process_webhook_data"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."search_nomecontatos"("p_input" character varying) RETURNS TABLE("nome" character varying)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT nome FROM contatos WHERE nome ILIKE '%' || p_input || '%';
END; 
$$;

ALTER FUNCTION "public"."search_nomecontatos"("p_input" character varying) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."search_username"("p_input" character varying) RETURNS TABLE("username" character varying)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT username FROM colab_user WHERE username LIKE '%' || victor || '%';
END; 
$$;

ALTER FUNCTION "public"."search_username"("p_input" character varying) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."searchnomecontatos"("search_text" "text") RETURNS TABLE("nome" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT nome FROM contatos WHERE nome ILIKE '%' || search_text || '%';
END;
$$;

ALTER FUNCTION "public"."searchnomecontatos"("search_text" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."searchnomeconversas"("search_text" "text") RETURNS TABLE("nome_contato" "text", "foto_contato" "text", "ultima_mensagem" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT 
    conversas.nome_contato, 
    conversas.foto_contato, 
    conversas.ultima_mensagem 
  FROM conversas 
  WHERE conversas.nome_contato ILIKE '%' || search_text || '%';
END;
$$;

ALTER FUNCTION "public"."searchnomeconversas"("search_text" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."searchnomeconversascerta"("search_text" "text") RETURNS TABLE("nome_contato" "text", "foto_contato" "text", "ultima_mensagem" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT 
    conversas.nome_contato, 
    conversas.foto_contato, 
    conversas.ultima_mensagem 
  FROM conversas 
  WHERE conversas.nome_contato ILIKE '%' || search_text || '%';
END;
$$;

ALTER FUNCTION "public"."searchnomeconversascerta"("search_text" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."searchnomeconversasuptade"("search_text" "text") RETURNS TABLE("nome_contato" "text", "horario_ultima_mensagem" timestamp without time zone, "foto_contato" "text", "ultima_mensagem" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT 
    conversas.nome_contato, 
    conversas.horario_ultima_mensagem, 
    conversas.foto_contato, 
    conversas.ultima_mensagem 
  FROM conversas 
  WHERE conversas.nome_contato ILIKE '%' || search_text || '%';
END;
$$;

ALTER FUNCTION "public"."searchnomeconversasuptade"("search_text" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."sossego_please"() RETURNS TABLE("id" bigint, "ref_message" bigint, "nome_contato" character varying, "messages_text" "text", "ref_colabuser" bigint, "ref_contatos" bigint, "authid" "uuid", "created_at" timestamp with time zone, "atualizado" boolean)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
    SELECT 
      conversas.id,
      conversas.ref_message,
      contatos.nome AS nome_contato,
      messages.text AS messages_text,
      conversas.ref_colabuser, 
      conversas.ref_contatos, 
      conversas.authid,
      conversas.created_at,
      conversas.atualizado
    FROM conversas
    JOIN contatos ON conversas.ref_contatos = contatos.id
    JOIN messages ON conversas.ref_message = messages.id;
END;
$$;

ALTER FUNCTION "public"."sossego_please"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_conexao_nomenclatura"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    nome_conexao TEXT;
BEGIN
    -- Buscar o nome da conexão correspondente na tabela conexoes
    BEGIN
        SELECT "Nome" INTO nome_conexao
        FROM conexoes
        WHERE instance_key = NEW.key_instancia;
        
        -- Se a consulta não encontrou nenhum resultado, nome_conexao será NULL
        -- Nesse caso, você pode definir um valor padrão ou lidar com isso conforme necessário
        -- Exemplo de tratamento: se nome_conexao é NULL, define como 'Desconhecido'
        IF nome_conexao IS NULL THEN
            nome_conexao := 'Desconhecido';
        END IF;

        -- Atribuir o valor encontrado ou tratado para NEW.conexao_nomenclatura
        NEW.conexao_nomenclatura := nome_conexao;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Tratamento para nenhum dado encontrado na consulta
            RAISE NOTICE 'Nenhuma conexão encontrada para instance_key %', NEW.key_instancia;
            -- Pode definir um valor padrão ou fazer outra ação conforme necessário
            NEW.conexao_nomenclatura := 'Desconhecido';
    END;
    
    -- Retornar a linha modificada para ser escrita no banco de dados
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_conexao_nomenclatura"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_keyconexao_setoreconexao"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Verifica se a coluna keyConexao é NULL
  IF NEW."keyConexao" IS NULL THEN
    -- Seleciona o instance_key da tabela conexoes correspondente ao id_conexao inserido
    SELECT instance_key INTO NEW."keyConexao"
    FROM public.conexoes
    WHERE id = NEW.id_conexao;

    -- Caso instance_key também seja NULL, você pode decidir como proceder,
    -- por exemplo, definindo um valor padrão ou deixando como NULL.
    IF NEW."keyConexao" IS NULL THEN
      NEW."keyConexao" := 'Valor padrão';  -- Substitua 'Valor padrão' conforme necessário
    END IF;
  END IF;

  -- Retorna o registro modificado para ser usado na inserção
  RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_keyconexao_setoreconexao"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_nome_conexao_por_nome_setorconexao"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE public.setor_conexao
    SET nome_conexao = NEW."Nome"
    WHERE id_conexao = NEW.id;

    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_nome_conexao_por_nome_setorconexao"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_nome_conexao_setorconexao"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Busca o nome da conexão baseado no id_conexao inserido/atualizado
    SELECT "Nome" INTO NEW.nome_conexao
    FROM public.conexoes
    WHERE id = NEW.id_conexao;
    
    -- Retorna o registro atualizado
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_nome_conexao_setorconexao"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_nome_setor_setorconexao"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Busca o nome do setor baseado no id_setor inserido/atualizado
    SELECT "Nome" INTO NEW.nome_setor
    FROM public."Setores"
    WHERE id = NEW.id_setor;
    
    -- Retorna o registro atualizado
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_nome_setor_setorconexao"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_responsavel_nome"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Atualiza 'responsavel_nome' com base no 'id_responsavel' atualizado ou inserido
    SELECT username INTO NEW.responsavel_nome FROM colab_user WHERE id = NEW.id_responsavel;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_responsavel_nome"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_setor_nome_conversas"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF TG_TABLE_NAME = 'conversas' AND NEW.id_setor IS NOT NULL THEN
        SELECT "Nome" INTO NEW."Setor_nomenclatura" FROM "Setores" WHERE id = NEW.id_setor;
    END IF;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_setor_nome_conversas"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_status_conversa"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE contatos
    SET status_conversa = NEW."Status"
    WHERE ref_conversa = NEW.id;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."update_status_conversa"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."upload_file_and_insert_url"("file" "bytea", "filename" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    file_url text;
BEGIN
    file_url := perform_upload_to_storage(file, filename, 'chat', 'arquivos');
    INSERT INTO mensagens (text) VALUES (file_url);
    RETURN file_url;
END;
$$;

ALTER FUNCTION "public"."upload_file_and_insert_url"("file" "bytea", "filename" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."verificar_conversa_ativa"("p_id_empresa" bigint, "p_numero_contato" "text", "p_key_instancia" "text") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_conversa_ativa boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM conversas
        WHERE ref_empresa = p_id_empresa
        AND numero_contato = p_numero_contato
        AND key_instancia = p_key_instancia
        AND "Status" NOT IN ('Finalizado', 'Visualizar')
    ) INTO v_conversa_ativa;

    RETURN v_conversa_ativa;
END;
$$;

ALTER FUNCTION "public"."verificar_conversa_ativa"("p_id_empresa" bigint, "p_numero_contato" "text", "p_key_instancia" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."verificar_numero_existente_em_contatos"("numero_a_verificar" character varying, "empresa_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    existe boolean;
BEGIN
    SELECT EXISTS(
        SELECT 1
        FROM contatos
        WHERE (numero = numero_a_verificar OR numero_relatorios = numero_a_verificar)
          AND ref_empresa = empresa_id
          AND isdeleted_contatos = FALSE
    ) INTO existe;
    
    RETURN existe;
END;
$$;

ALTER FUNCTION "public"."verificar_numero_existente_em_contatos"("numero_a_verificar" character varying, "empresa_id" bigint) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."webhook_per_day_current_week"() RETURNS TABLE("day_name" "text", "day_of_week" integer, "total_webhooks" integer)
    LANGUAGE "sql" STABLE
    AS $$
WITH WeekDays AS (
    SELECT 0 AS day_of_week, 'Domingo' AS day_name UNION ALL
    SELECT 1, 'Segunda-feira' UNION ALL
    SELECT 2, 'Terça-feira' UNION ALL
    SELECT 3, 'Quarta-feira' UNION ALL
    SELECT 4, 'Quinta-feira' UNION ALL
    SELECT 5, 'Sexta-feira' UNION ALL
    SELECT 6, 'Sábado'
)

SELECT
    wd.day_name,
    wd.day_of_week,
    COALESCE(COUNT(w.created_at), 0) as total_webhooks
FROM WeekDays wd
LEFT JOIN webhook w
    ON EXTRACT(DOW FROM w.created_at) = wd.day_of_week
    AND w.created_at >= date_trunc('week', CURRENT_DATE)
GROUP BY wd.day_name, wd.day_of_week
ORDER BY wd.day_of_week;
$$;

ALTER FUNCTION "public"."webhook_per_day_current_week"() OWNER TO "postgres";

ALTER TABLE "public"."Bot" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Bot_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."Empresa" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Empresa_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."Encerramento_Assunto" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "assunto" "text" DEFAULT ''::"text",
    "ref_empresa" bigint DEFAULT '1'::bigint NOT NULL,
    "isdeleted_assunto" boolean DEFAULT false
);

ALTER TABLE "public"."Encerramento_Assunto" OWNER TO "postgres";

ALTER TABLE "public"."Encerramento_Assunto" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Encerramento_Assunto_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."Encerramento_Tag" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Tag" "text",
    "ref_empresa" bigint DEFAULT '1'::bigint NOT NULL,
    "isdeleted_tag" boolean DEFAULT false
);

ALTER TABLE "public"."Encerramento_Tag" OWNER TO "postgres";

ALTER TABLE "public"."Encerramento_Tag" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Encerramento_Tag_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."Respostas_Rapidas" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Texto" "text",
    "Atalho" "text",
    "Setor" "text",
    "id_empresa" bigint DEFAULT '1'::bigint NOT NULL,
    "id_setor" bigint,
    "isdeleted_resposta" boolean DEFAULT false
);

ALTER TABLE "public"."Respostas_Rapidas" OWNER TO "postgres";

ALTER TABLE "public"."Respostas_Rapidas" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Respostas Rápidas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."Setores" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Nome" "text",
    "responsavel_nome" character varying,
    "numero_conversas" numeric,
    "numero_transferencias" numeric,
    "numero_espera" numeric,
    "id_empresas" bigint DEFAULT '1'::bigint NOT NULL,
    "id_responsavel" bigint,
    "ordem" bigint,
    "id_conexao" bigint,
    "key_conexao" "text",
    "ativo_bot" boolean DEFAULT true,
    "isdeleted_setor" boolean DEFAULT false
);

ALTER TABLE "public"."Setores" OWNER TO "postgres";

ALTER TABLE "public"."Setores" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Setores_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."colab_user" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."colab user_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."conexoes" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."conexoes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."contatos" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."contatos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."contatos_resumo" AS
 SELECT "c"."ref_empresa",
    "count"(*) AS "total_registros",
    "count"(*) FILTER (WHERE ("date_trunc"('month'::"text", "c"."created_at") = "date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))) AS "novos_registros_mensais"
   FROM "public"."contatos" "c"
  WHERE ("c"."isdeleted_contatos" <> true)
  GROUP BY "c"."ref_empresa";

ALTER TABLE "public"."contatos_resumo" OWNER TO "postgres";

ALTER TABLE "public"."conversas" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."conversas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."conversas_relatorio" AS
 SELECT "conversas"."id",
    "conversas"."ref_empresa",
    "conversas"."Status",
    "conversas"."foto_contato",
    "conversas"."nome_contato",
    "conversas"."numero_contato",
    "conversas"."Setor_nomenclatura",
    "conversas"."conexao_nomenclatura",
    "conversas"."colabuser_nome",
    "conversas"."created_at",
    "conversas"."hora_finalizada",
    "conversas"."Protocolo",
    "conversas"."istransferida"
   FROM "public"."conversas"
  WHERE (("conversas"."Status" <> 'Visualizar'::"text") AND ("conversas"."isdeleted_conversas" = false) AND ("conversas"."transferida_setor" IS NULL));

ALTER TABLE "public"."conversas_relatorio" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."conversas_test" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ref_contatos" bigint,
    "authid" "uuid",
    "atualizado" boolean DEFAULT false,
    "nome_contato" "text",
    "foto_contato" "text",
    "arquivada" boolean DEFAULT false,
    "ultima_mensagem" "text" DEFAULT 'vazio'::"text",
    "horario_ultima_mensagem" timestamp with time zone DEFAULT "now"(),
    "Protocolo" "text" DEFAULT ("floor"(("random"() * (((10)::double precision ^ (8)::double precision) - ((10)::double precision ^ (7)::double precision)))) + ((10)::double precision ^ (7)::double precision)),
    "Status" "text" DEFAULT 'Bot'::"text",
    "numero_contato" "text" DEFAULT '999999999'::"text",
    "Setor_nomenclatura" "text",
    "colabuser_nome" "text",
    "hora_finalizada" timestamp with time zone,
    "ref_empresa" bigint,
    "empresa_nome" "text",
    "Encerramento_assunto" "text",
    "Encerramento_tag" "text",
    "Relato_conversa" "text",
    "observacao_transferencia" "text",
    "updated_at" timestamp with time zone,
    "webhook_id_ultima" bigint,
    "id_setor" bigint,
    "key_instancia" "text",
    "id_api" "text",
    "transferida_setor" bigint,
    "transferida_user" "uuid",
    "foto_colabUser" "text",
    "transferida_nome_user" "text",
    "transferida_nome_setor" character varying,
    "isdeleted_conversas" boolean DEFAULT false,
    "istransferida" boolean DEFAULT false,
    "isforahorario" boolean DEFAULT false,
    "isespera" boolean DEFAULT false,
    "fixa" boolean DEFAULT false,
    "conexao_nomenclatura" "text"
);

ALTER TABLE "public"."conversas_test" OWNER TO "postgres";

ALTER TABLE "public"."conversas_test" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."conversas_test_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."daily_conversations_comparison" AS
 SELECT "conversas"."ref_empresa",
    "conversas"."empresa_nome",
    CURRENT_DATE AS "data",
    "count"(*) AS "conversas_hoje",
    "lag"("count"(*), 1) OVER (PARTITION BY "conversas"."ref_empresa" ORDER BY CURRENT_DATE) AS "conversas_ontem",
    COALESCE((((("count"(*) - "lag"("count"(*), 1) OVER (PARTITION BY "conversas"."ref_empresa" ORDER BY CURRENT_DATE)))::double precision / ("lag"("count"(*), 1) OVER (PARTITION BY "conversas"."ref_empresa" ORDER BY CURRENT_DATE))::double precision) * (100)::double precision), (0)::double precision) AS "percentual_mudanca"
   FROM "public"."conversas"
  WHERE ((("conversas"."created_at")::"date" = CURRENT_DATE) OR (("conversas"."created_at")::"date" = (CURRENT_DATE - 1)))
  GROUP BY "conversas"."ref_empresa", "conversas"."empresa_nome", (("conversas"."created_at")::"date")
  ORDER BY "conversas"."ref_empresa", CURRENT_DATE DESC;

ALTER TABLE "public"."daily_conversations_comparison" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."daily_conversations_comparison1" AS
 WITH "uniquecompanies" AS (
         SELECT DISTINCT "conversas"."ref_empresa"
           FROM "public"."conversas"
        ), "todayconversations" AS (
         SELECT "conversas"."ref_empresa",
            "count"(*) AS "today_count"
           FROM "public"."conversas"
          WHERE ("date"("conversas"."created_at") = CURRENT_DATE)
          GROUP BY "conversas"."ref_empresa"
        ), "yesterdayconversations" AS (
         SELECT "conversas"."ref_empresa",
            "count"(*) AS "yesterday_count"
           FROM "public"."conversas"
          WHERE ("date"("conversas"."created_at") = (CURRENT_DATE - '1 day'::interval))
          GROUP BY "conversas"."ref_empresa"
        )
 SELECT "uc"."ref_empresa",
    COALESCE("tc"."today_count", (0)::bigint) AS "today_count",
    COALESCE("yc"."yesterday_count", (0)::bigint) AS "yesterday_count",
        CASE
            WHEN ((COALESCE("yc"."yesterday_count", (0)::bigint) + COALESCE("tc"."today_count", (0)::bigint)) = 0) THEN (0)::numeric
            ELSE COALESCE("round"(((((COALESCE("tc"."today_count", (0)::bigint))::numeric - (COALESCE("yc"."yesterday_count", (0)::bigint))::numeric) / (NULLIF(COALESCE("yc"."yesterday_count", (0)::bigint), 0))::numeric) * (100)::numeric), 2), (0)::numeric)
        END AS "percentage_change"
   FROM (("uniquecompanies" "uc"
     LEFT JOIN "todayconversations" "tc" ON (("uc"."ref_empresa" = "tc"."ref_empresa")))
     LEFT JOIN "yesterdayconversations" "yc" ON (("uc"."ref_empresa" = "yc"."ref_empresa")));

ALTER TABLE "public"."daily_conversations_comparison1" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."espera_status_stats" AS
 WITH "uniquecompanies" AS (
         SELECT DISTINCT "conversas"."ref_empresa"
           FROM "public"."conversas"
        ), "esperadurations" AS (
         SELECT "c"."ref_empresa",
            COALESCE((EXTRACT(epoch FROM (
                CASE
                    WHEN ("c"."updated_at" IS NOT NULL) THEN "c"."updated_at"
                    ELSE CURRENT_TIMESTAMP
                END - "c"."created_at")) / (60)::numeric), (0)::numeric) AS "duration_minutes"
           FROM "public"."conversas" "c"
          WHERE ("c"."Status" = 'Espera'::"text")
        )
 SELECT "uc"."ref_empresa",
    COALESCE("count"("ed"."duration_minutes"), (0)::bigint) AS "total_espera_conversas",
    COALESCE("round"("avg"("ed"."duration_minutes"), 2), (0)::numeric) AS "avg_duration_minutes"
   FROM ("uniquecompanies" "uc"
     LEFT JOIN "esperadurations" "ed" ON (("uc"."ref_empresa" = "ed"."ref_empresa")))
  GROUP BY "uc"."ref_empresa";

ALTER TABLE "public"."espera_status_stats" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."finalized_conversations_this_month" AS
 WITH "currentmonth" AS (
         SELECT "conversas"."ref_empresa",
            "count"(*) AS "current_month_count"
           FROM "public"."conversas"
          WHERE (("conversas"."Status" = 'Finalizado'::"text") AND (("date"("conversas"."created_at") >= "date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone)) AND ("date"("conversas"."created_at") <= CURRENT_DATE)))
          GROUP BY "conversas"."ref_empresa"
        ), "previousmonth" AS (
         SELECT "conversas"."ref_empresa",
            "count"(*) AS "previous_month_count"
           FROM "public"."conversas"
          WHERE (("conversas"."Status" = 'Finalizado'::"text") AND (("date"("conversas"."created_at") >= ("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone) - '1 mon'::interval)) AND ("date"("conversas"."created_at") <= ("date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone) - '1 day'::interval))))
          GROUP BY "conversas"."ref_empresa"
        )
 SELECT "e"."id" AS "ref_empresa",
    COALESCE("cm"."current_month_count", (0)::bigint) AS "current_month_count",
    COALESCE("pm"."previous_month_count", (0)::bigint) AS "previous_month_count",
        CASE
            WHEN (COALESCE("pm"."previous_month_count", (0)::bigint) = 0) THEN (0)::numeric
            ELSE "round"(((((COALESCE("cm"."current_month_count", (0)::bigint))::numeric - (COALESCE("pm"."previous_month_count", (0)::bigint))::numeric) / (NULLIF(COALESCE("pm"."previous_month_count", (0)::bigint), 0))::numeric) * (100)::numeric), 2)
        END AS "percentage_change"
   FROM (("public"."Empresa" "e"
     LEFT JOIN "currentmonth" "cm" ON (("e"."id" = "cm"."ref_empresa")))
     LEFT JOIN "previousmonth" "pm" ON (("e"."id" = "pm"."ref_empresa")));

ALTER TABLE "public"."finalized_conversations_this_month" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."setor_conexao" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id_setor" bigint,
    "id_conexao" bigint,
    "id_empresa" bigint,
    "keyConexao" "text",
    "nome_conexao" "text",
    "nome_setor" "text"
);

ALTER TABLE "public"."setor_conexao" OWNER TO "postgres";

ALTER TABLE "public"."setor_conexao" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."setor_conexao_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."setores_users" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "setor_id" bigint,
    "colab_id" "uuid",
    "id_empresa" bigint,
    "nome_colabUser" "text"
);

ALTER TABLE "public"."setores_users" OWNER TO "postgres";

ALTER TABLE "public"."setores_users" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."setores_users_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."top_setores" AS
 WITH "ranked_sectors" AS (
         SELECT "s"."id_empresas" AS "id_empresa",
            "s"."id" AS "id_setor",
            "s"."Nome" AS "nome_setor",
            "count"("c"."id") AS "numero_conversas",
            "count"("w"."id") AS "numero_webhooks",
            "row_number"() OVER (PARTITION BY "s"."id_empresas" ORDER BY ("count"("c"."id")) DESC, ("count"("w"."id")) DESC) AS "rank"
           FROM (("public"."Setores" "s"
             LEFT JOIN "public"."conversas" "c" ON (("s"."id" = "c"."id_setor")))
             LEFT JOIN "public"."webhook" "w" ON ((("c"."id")::"text" = "w"."id_api_conversa")))
          GROUP BY "s"."id_empresas", "s"."id", "s"."Nome"
        )
 SELECT "ranked_sectors"."id_empresa",
    "ranked_sectors"."id_setor",
    "ranked_sectors"."nome_setor",
    "ranked_sectors"."numero_conversas",
    "ranked_sectors"."numero_webhooks"
   FROM "ranked_sectors"
  WHERE ("ranked_sectors"."rank" <= 4);

ALTER TABLE "public"."top_setores" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."total_conexoes" AS
 SELECT "e"."id" AS "id_empresa",
    "count"("c"."id_empresa") AS "total",
    "count"(
        CASE
            WHEN ("c"."Status" = true) THEN 1
            ELSE NULL::integer
        END) AS "total_ativos"
   FROM ("public"."Empresa" "e"
     LEFT JOIN "public"."conexoes" "c" ON (("e"."id" = "c"."id_empresa")))
  GROUP BY "e"."id";

ALTER TABLE "public"."total_conexoes" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."total_setores" AS
 SELECT "e"."id" AS "id_empresas",
    COALESCE("count"("s"."id_empresas"), (0)::bigint) AS "total"
   FROM ("public"."Empresa" "e"
     LEFT JOIN "public"."Setores" "s" ON (("e"."id" = "s"."id_empresas")))
  GROUP BY "e"."id";

ALTER TABLE "public"."total_setores" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_chatconversas_espera" AS
 SELECT "conversas"."id",
    "conversas"."id_setor",
    "conversas"."ref_empresa",
    "conversas"."foto_contato",
    "conversas"."nome_contato",
    "conversas"."ultima_mensagem",
    "conversas"."horario_ultima_mensagem",
    "conversas"."atualizado",
    "conversas"."foto_colabUser",
    "conversas"."key_instancia",
    "conversas"."id_api",
    "conversas"."isespera",
    "conversas"."istransferida",
    "conversas"."isforahorario"
   FROM "public"."conversas"
  WHERE ("conversas"."Status" = 'Espera'::"text")
  ORDER BY "conversas"."atualizado", "conversas"."created_at" DESC;

ALTER TABLE "public"."view_chatconversas_espera" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_colab_user_summary" AS
 SELECT "cu"."id_empresa",
    "count"(*) AS "total_registros",
    "count"(*) FILTER (WHERE ("cu"."online" = true)) AS "total_online",
    "count"(*) FILTER (WHERE ("cu"."online" = false)) AS "total_offline",
    "count"(*) FILTER (WHERE ("cu"."Tipo" = 'Administrador'::"text")) AS "total_administrador",
    "count"(*) FILTER (WHERE (("cu"."Tipo" = 'Operador'::"text") AND ("cu"."online" = false))) AS "total_operador_offline",
    "count"(*) FILTER (WHERE (("cu"."Tipo" = 'Operador'::"text") AND ("cu"."online" = true))) AS "total_operador_online",
    "count"(*) FILTER (WHERE ("cu"."Tipo" = 'Operador'::"text")) AS "total_operador",
    "count"(*) FILTER (WHERE ("cu"."ativo" = true)) AS "total_ativo",
    "count"(*) FILTER (WHERE ("cu"."ativo" = false)) AS "total_inativo"
   FROM "public"."colab_user" "cu"
  GROUP BY "cu"."id_empresa";

ALTER TABLE "public"."view_colab_user_summary" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_contagem_webhook" AS
 SELECT "c"."id_api" AS "id_contato_conversas",
    "count"("w".*) AS "contagem_nao_lidos"
   FROM ("public"."webhook" "w"
     JOIN "public"."conversas" "c" ON (("c"."id_api" = "w"."id_api_conversa")))
  WHERE (("w"."Lida" = false) AND ("w"."fromMe" = false))
  GROUP BY "c"."id_api";

ALTER TABLE "public"."view_contagem_webhook" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_conversas_em_atendimento_por_usuario" AS
SELECT
    NULL::bigint AS "colab_user_id",
    NULL::character varying AS "username",
    NULL::"uuid" AS "auth_id",
    NULL::bigint AS "numero_de_conversas_em_atendimento";

ALTER TABLE "public"."view_conversas_em_atendimento_por_usuario" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_conversas_espera_por_usuario" AS
 SELECT "cu"."auth_id" AS "usuario_auth_id",
    "cu"."username" AS "nome_usuario",
    "count"("c"."id") FILTER (WHERE ("c"."Status" = 'Espera'::"text")) AS "numero_de_conversas_em_espera"
   FROM (("public"."colab_user" "cu"
     JOIN "public"."setores_users" "su" ON (("cu"."auth_id" = "su"."colab_id")))
     LEFT JOIN "public"."conversas" "c" ON (("su"."setor_id" = "c"."id_setor")))
  GROUP BY "cu"."auth_id", "cu"."username";

ALTER TABLE "public"."view_conversas_espera_por_usuario" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_conversas_filtradas" AS
 SELECT "count"(*) AS "count"
   FROM "public"."conversas"
  WHERE (("conversas"."ref_empresa" = "conversas"."ref_empresa") AND ("conversas"."Status" = 'Em Atendimento'::"text") AND ("conversas"."authid" = "conversas"."authid"));

ALTER TABLE "public"."view_conversas_filtradas" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_conversas_por_empresa" AS
 SELECT "e"."id" AS "ref_empresa",
    COALESCE("c"."conversas_count", (0)::bigint) AS "numero_de_conversas"
   FROM ("public"."Empresa" "e"
     LEFT JOIN ( SELECT "conversas"."ref_empresa",
            "count"(*) AS "conversas_count"
           FROM "public"."conversas"
          WHERE (("conversas"."Status" <> 'Visualizar'::"text") AND ("conversas"."isdeleted_conversas" = false) AND ("conversas"."transferida_setor" IS NULL))
          GROUP BY "conversas"."ref_empresa") "c" ON (("e"."id" = "c"."ref_empresa")));

ALTER TABLE "public"."view_conversas_por_empresa" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_conversas_por_usuario" AS
 SELECT "conversas"."id",
    "conversas"."ultima_mensagem",
    "conversas"."fixa",
    "conversas"."horario_ultima_mensagem",
    "conversas"."atualizado",
    "conversas"."nome_contato",
    "conversas"."id_api",
    "conversas"."foto_contato",
    "conversas"."authid",
    "conversas"."foto_colabUser",
    "conversas"."key_instancia"
   FROM "public"."conversas"
  WHERE ("conversas"."Status" = 'Em Atendimento'::"text")
  ORDER BY "conversas"."fixa" DESC, "conversas"."horario_ultima_mensagem" DESC, "conversas"."atualizado", "conversas"."id";

ALTER TABLE "public"."view_conversas_por_usuario" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."view_setor_colab_count" AS
 SELECT "s"."id",
    "s"."Nome",
    COALESCE("c"."count_colab", (0)::bigint) AS "num_colab_users"
   FROM ("public"."Setores" "s"
     LEFT JOIN ( SELECT "su"."setor_id",
            "count"(*) AS "count_colab"
           FROM ("public"."setores_users" "su"
             JOIN "public"."colab_user" "cu" ON (("su"."colab_id" = "cu"."auth_id")))
          GROUP BY "su"."setor_id") "c" ON (("s"."id" = "c"."setor_id")));

ALTER TABLE "public"."view_setor_colab_count" OWNER TO "postgres";

ALTER TABLE "public"."webhook" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."webhook_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."webhook_per_day_current_week" AS
 WITH "weekdays" AS (
         SELECT 0 AS "day_of_week",
            'Domingo'::"text" AS "day_name"
        UNION ALL
         SELECT 1,
            'Segunda-feira'::"text"
        UNION ALL
         SELECT 2,
            'Terça-feira'::"text"
        UNION ALL
         SELECT 3,
            'Quarta-feira'::"text"
        UNION ALL
         SELECT 4,
            'Quinta-feira'::"text"
        UNION ALL
         SELECT 5,
            'Sexta-feira'::"text"
        UNION ALL
         SELECT 6,
            'Sábado'::"text"
        ), "allempresas" AS (
         SELECT DISTINCT "conexoes"."id_empresa"
           FROM "public"."conexoes"
        ), "webhooksbyday" AS (
         SELECT EXTRACT(dow FROM "w"."created_at") AS "day_of_week",
            "c"."id_empresa",
            "count"("w"."id") AS "total_webhooks"
           FROM ("public"."webhook" "w"
             JOIN "public"."conexoes" "c" ON (("w"."instance_key" = "c"."instance_key")))
          WHERE ("w"."created_at" >= "date_trunc"('week'::"text", (CURRENT_DATE)::timestamp with time zone))
          GROUP BY (EXTRACT(dow FROM "w"."created_at")), "c"."id_empresa"
        )
 SELECT "wd"."day_name",
    "wd"."day_of_week",
    "ae"."id_empresa",
    COALESCE("wbd"."total_webhooks", (0)::bigint) AS "total_webhooks"
   FROM (("weekdays" "wd"
     CROSS JOIN "allempresas" "ae")
     LEFT JOIN "webhooksbyday" "wbd" ON (((("wd"."day_of_week")::numeric = "wbd"."day_of_week") AND ("ae"."id_empresa" = "wbd"."id_empresa"))))
  ORDER BY "wd"."day_of_week", "ae"."id_empresa";

ALTER TABLE "public"."webhook_per_day_current_week" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."weekly_contact_comparison" AS
 WITH "currentweekcontacts" AS (
         SELECT "contatos"."ref_empresa",
            "count"(*) AS "current_week_count"
           FROM "public"."contatos"
          WHERE (("date"("contatos"."created_at") >= "date_trunc"('week'::"text", (CURRENT_DATE)::timestamp with time zone)) AND ("date"("contatos"."created_at") <= CURRENT_DATE))
          GROUP BY "contatos"."ref_empresa"
        ), "previousweekcontacts" AS (
         SELECT "contatos"."ref_empresa",
            "count"(*) AS "previous_week_count"
           FROM "public"."contatos"
          WHERE (("date"("contatos"."created_at") >= ("date_trunc"('week'::"text", (CURRENT_DATE)::timestamp with time zone) - '7 days'::interval)) AND ("date"("contatos"."created_at") <= ("date_trunc"('week'::"text", (CURRENT_DATE)::timestamp with time zone) - '1 day'::interval)))
          GROUP BY "contatos"."ref_empresa"
        )
 SELECT "e"."id" AS "ref_empresa",
    COALESCE("cwc"."current_week_count", (0)::bigint) AS "current_week_count",
    COALESCE("pwc"."previous_week_count", (0)::bigint) AS "previous_week_count",
        CASE
            WHEN (COALESCE("pwc"."previous_week_count", (0)::bigint) = 0) THEN (0)::numeric
            ELSE "round"(((((COALESCE("cwc"."current_week_count", (0)::bigint))::numeric - (COALESCE("pwc"."previous_week_count", (0)::bigint))::numeric) / (NULLIF(COALESCE("pwc"."previous_week_count", (0)::bigint), 0))::numeric) * (100)::numeric), 2)
        END AS "percentage_change"
   FROM (("public"."Empresa" "e"
     LEFT JOIN "currentweekcontacts" "cwc" ON (("e"."id" = "cwc"."ref_empresa")))
     LEFT JOIN "previousweekcontacts" "pwc" ON (("e"."id" = "pwc"."ref_empresa")));

ALTER TABLE "public"."weekly_contact_comparison" OWNER TO "postgres";

ALTER TABLE ONLY "public"."Bot"
    ADD CONSTRAINT "Bot_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."Empresa"
    ADD CONSTRAINT "Empresa_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."Encerramento_Assunto"
    ADD CONSTRAINT "Encerramento_Assunto_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."Encerramento_Tag"
    ADD CONSTRAINT "Encerramento_Tag_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."Respostas_Rapidas"
    ADD CONSTRAINT "Respostas Rápidas_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."Setores"
    ADD CONSTRAINT "Setores_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."colab_user"
    ADD CONSTRAINT "colab user_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."colab_user"
    ADD CONSTRAINT "colab_user_auth_id_key" UNIQUE ("auth_id");

ALTER TABLE ONLY "public"."conexoes"
    ADD CONSTRAINT "conexoes_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."contatos"
    ADD CONSTRAINT "contatos_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."setor_conexao"
    ADD CONSTRAINT "setor_conexao_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."setores_users"
    ADD CONSTRAINT "setores_users_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."setor_conexao"
    ADD CONSTRAINT "uq_setor_conexao_unique_combination" UNIQUE ("id_conexao", "id_setor", "id_empresa");

ALTER TABLE ONLY "public"."webhook"
    ADD CONSTRAINT "webhook_pkey" PRIMARY KEY ("id");

CREATE OR REPLACE VIEW "public"."view_conversas_em_atendimento_por_usuario" AS
 SELECT "cu"."id" AS "colab_user_id",
    "cu"."username",
    "cu"."auth_id",
    "count"("c"."id") AS "numero_de_conversas_em_atendimento"
   FROM ("public"."colab_user" "cu"
     LEFT JOIN "public"."conversas" "c" ON (("cu"."auth_id" = "c"."authid")))
  WHERE ("c"."Status" = 'Em Atendimento'::"text")
  GROUP BY "cu"."id";

CREATE OR REPLACE TRIGGER "atualizar_webhook_trigger" BEFORE UPDATE ON "public"."webhook" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_webhook"();

CREATE OR REPLACE TRIGGER "setores_responsavel_update" BEFORE INSERT OR UPDATE OF "id_responsavel" ON "public"."Setores" FOR EACH ROW EXECUTE FUNCTION "public"."update_responsavel_nome"();

CREATE OR REPLACE TRIGGER "setores_users_after_insert_or_update_or_delete" AFTER INSERT OR DELETE OR UPDATE ON "public"."setores_users" FOR EACH ROW EXECUTE FUNCTION "public"."atualiza_setores_nomes"();

CREATE OR REPLACE TRIGGER "tr_process_chat_data" BEFORE INSERT OR UPDATE ON "public"."webhook" FOR EACH ROW EXECUTE FUNCTION "public"."process_chat_data"();

CREATE OR REPLACE TRIGGER "tr_process_webhook_data" BEFORE INSERT OR UPDATE ON "public"."webhook" FOR EACH ROW EXECUTE FUNCTION "public"."process_webhook_data"();

CREATE OR REPLACE TRIGGER "trg_update_keyconexao" BEFORE INSERT ON "public"."setor_conexao" FOR EACH ROW EXECUTE FUNCTION "public"."update_keyconexao_setoreconexao"();

CREATE OR REPLACE TRIGGER "trg_update_nome_conexao_por_nome_setorconexao" AFTER UPDATE OF "Nome" ON "public"."conexoes" FOR EACH ROW WHEN (("old"."Nome" IS DISTINCT FROM "new"."Nome")) EXECUTE FUNCTION "public"."update_nome_conexao_por_nome_setorconexao"();

CREATE OR REPLACE TRIGGER "trg_update_nome_conexao_setorconexao" BEFORE INSERT OR UPDATE OF "id_conexao" ON "public"."setor_conexao" FOR EACH ROW EXECUTE FUNCTION "public"."update_nome_conexao_setorconexao"();

CREATE OR REPLACE TRIGGER "trg_update_nome_setor_setorconexao" BEFORE INSERT OR UPDATE OF "id_setor" ON "public"."setor_conexao" FOR EACH ROW EXECUTE FUNCTION "public"."update_nome_setor_setorconexao"();

CREATE OR REPLACE TRIGGER "trigger_atualiza_colab_user_apos_insert" AFTER INSERT ON "public"."colab_user" FOR EACH ROW EXECUTE FUNCTION "public"."atualiza_informacoes_colab_user"();

CREATE OR REPLACE TRIGGER "trigger_atualiza_colab_user_apos_update" AFTER UPDATE ON "public"."colab_user" FOR EACH ROW EXECUTE FUNCTION "public"."atualiza_informacoes_colab_user"();

CREATE OR REPLACE TRIGGER "trigger_atualiza_conexao_nomenclatura" BEFORE UPDATE ON "public"."conversas" FOR EACH ROW EXECUTE FUNCTION "public"."update_conexao_nomenclatura"();

CREATE OR REPLACE TRIGGER "trigger_atualiza_conversas" AFTER INSERT ON "public"."webhook" FOR EACH ROW EXECUTE FUNCTION "public"."atualiza_conversas"();

CREATE OR REPLACE TRIGGER "trigger_atualiza_nome_setor_conversa" BEFORE INSERT OR UPDATE ON "public"."conversas" FOR EACH ROW EXECUTE FUNCTION "public"."update_setor_nome_conversas"();

CREATE OR REPLACE TRIGGER "trigger_atualiza_ref_empresa_conversas" AFTER INSERT ON "public"."conversas" FOR EACH ROW EXECUTE FUNCTION "public"."atualiza_ref_empresa_conversa"();

CREATE OR REPLACE TRIGGER "trigger_atualiza_ultima_mensagem_conversa" AFTER INSERT OR UPDATE ON "public"."webhook" FOR EACH ROW EXECUTE FUNCTION "public"."atualiza_ultima_mensagem_conversa"();

CREATE OR REPLACE TRIGGER "trigger_create_bot_after_company_insert" AFTER INSERT ON "public"."Empresa" FOR EACH ROW EXECUTE FUNCTION "public"."create_bot_for_new_company"();

CREATE OR REPLACE TRIGGER "trigger_update_status_conversa" AFTER UPDATE ON "public"."conversas" FOR EACH ROW EXECUTE FUNCTION "public"."update_status_conversa"();

CREATE OR REPLACE TRIGGER "verifica_ref_contato" AFTER INSERT OR UPDATE ON "public"."conversas" FOR EACH STATEMENT EXECUTE FUNCTION "public"."insere_contato_e_atualiza_conversa"();

CREATE OR REPLACE TRIGGER "webhookBot" AFTER INSERT ON "public"."webhook" FOR EACH ROW WHEN (("new"."is_edge_function_insert" = false)) EXECUTE FUNCTION "supabase_functions"."http_request"('https://fntyzzstyetnbvrpqfre.supabase.co/functions/v1/bot', 'POST', '{"Content-Type":"application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZudHl6enN0eWV0bmJ2cnBxZnJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE2OTExMTM0NzksImV4cCI6MjAwNjY4OTQ3OX0.eaod7DsHG3Pc1ZBFSmvr3r6by-MtNf0hzjgjXzdN3Jk"}', '{}', '2000');

ALTER TABLE ONLY "public"."Bot"
    ADD CONSTRAINT "Bot_id_empresa_fkey" FOREIGN KEY ("id_empresa") REFERENCES "public"."Empresa"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."Bot"
    ADD CONSTRAINT "Bot_setor_horario_fora_fkey" FOREIGN KEY ("setor_horario_fora") REFERENCES "public"."Setores"("id");

ALTER TABLE ONLY "public"."Bot"
    ADD CONSTRAINT "Bot_setor_inatividade_fkey" FOREIGN KEY ("setor_inatividade") REFERENCES "public"."Setores"("id");

ALTER TABLE ONLY "public"."Bot"
    ADD CONSTRAINT "Bot_setor_transferido_automaticamente_fkey" FOREIGN KEY ("setor_transferido_automaticamente") REFERENCES "public"."Setores"("id") ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY "public"."Empresa"
    ADD CONSTRAINT "Empresa_user_master_fkey" FOREIGN KEY ("user_master") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."Encerramento_Assunto"
    ADD CONSTRAINT "Encerramento_Assunto_ref_empresa_fkey" FOREIGN KEY ("ref_empresa") REFERENCES "public"."Empresa"("id");

ALTER TABLE ONLY "public"."Encerramento_Tag"
    ADD CONSTRAINT "Encerramento_Tag_ref_empresa_fkey" FOREIGN KEY ("ref_empresa") REFERENCES "public"."Empresa"("id");

ALTER TABLE ONLY "public"."Respostas_Rapidas"
    ADD CONSTRAINT "Respostas_Rapidas_id_empresa_fkey" FOREIGN KEY ("id_empresa") REFERENCES "public"."Empresa"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."Respostas_Rapidas"
    ADD CONSTRAINT "Respostas_Rapidas_id_setor_fkey" FOREIGN KEY ("id_setor") REFERENCES "public"."Setores"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."Setores"
    ADD CONSTRAINT "Setores_id_conexao_fkey" FOREIGN KEY ("id_conexao") REFERENCES "public"."conexoes"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."Setores"
    ADD CONSTRAINT "Setores_id_empresas_fkey" FOREIGN KEY ("id_empresas") REFERENCES "public"."Empresa"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."Setores"
    ADD CONSTRAINT "Setores_id_responsavel_fkey" FOREIGN KEY ("id_responsavel") REFERENCES "public"."colab_user"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."colab_user"
    ADD CONSTRAINT "colab_user_auth_id_fkey" FOREIGN KEY ("auth_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."colab_user"
    ADD CONSTRAINT "colab_user_id_empresa_fkey" FOREIGN KEY ("id_empresa") REFERENCES "public"."Empresa"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."colab_user"
    ADD CONSTRAINT "colab_user_setor_id_fkey" FOREIGN KEY ("setor_id") REFERENCES "public"."Setores"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."conexoes"
    ADD CONSTRAINT "conexoes_ Setor_Principal_fkey" FOREIGN KEY (" Setor_Principal") REFERENCES "public"."Setores"("id");

ALTER TABLE ONLY "public"."conexoes"
    ADD CONSTRAINT "conexoes_id_contato_retorno_fkey" FOREIGN KEY ("id_contato_retorno") REFERENCES "public"."contatos"("id") ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE ONLY "public"."conexoes"
    ADD CONSTRAINT "conexoes_id_empresa_fkey" FOREIGN KEY ("id_empresa") REFERENCES "public"."Empresa"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."conexoes"
    ADD CONSTRAINT "conexoes_user_fkey" FOREIGN KEY ("user") REFERENCES "public"."colab_user"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."contatos"
    ADD CONSTRAINT "contatos_authid_fkey" FOREIGN KEY ("authid") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."contatos"
    ADD CONSTRAINT "contatos_ref_conversa_fkey" FOREIGN KEY ("ref_conversa") REFERENCES "public"."conversas"("id");

ALTER TABLE ONLY "public"."contatos"
    ADD CONSTRAINT "contatos_ref_empresa_fkey" FOREIGN KEY ("ref_empresa") REFERENCES "public"."Empresa"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_authid_fkey" FOREIGN KEY ("authid") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_id_setor_fkey" FOREIGN KEY ("id_setor") REFERENCES "public"."Setores"("id");

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_ref_contatos_fkey" FOREIGN KEY ("ref_contatos") REFERENCES "public"."contatos"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_ref_empresa_fkey" FOREIGN KEY ("ref_empresa") REFERENCES "public"."Empresa"("id");

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_authid_fkey" FOREIGN KEY ("authid") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_id_setor_fkey" FOREIGN KEY ("id_setor") REFERENCES "public"."Setores"("id");

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_ref_contatos_fkey" FOREIGN KEY ("ref_contatos") REFERENCES "public"."contatos"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_ref_empresa_fkey" FOREIGN KEY ("ref_empresa") REFERENCES "public"."Empresa"("id");

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_transferida_setor_fkey" FOREIGN KEY ("transferida_setor") REFERENCES "public"."Setores"("id");

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_transferida_user_fkey" FOREIGN KEY ("transferida_user") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."conversas_test"
    ADD CONSTRAINT "conversas_test_webhook_id_ultima_fkey" FOREIGN KEY ("webhook_id_ultima") REFERENCES "public"."webhook"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_transferida_setor_fkey" FOREIGN KEY ("transferida_setor") REFERENCES "public"."Setores"("id");

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_transferida_user_fkey" FOREIGN KEY ("transferida_user") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."conversas"
    ADD CONSTRAINT "conversas_webhook_id_ultima_fkey" FOREIGN KEY ("webhook_id_ultima") REFERENCES "public"."webhook"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."setor_conexao"
    ADD CONSTRAINT "public_setor_conexao_id_conexao_fkey" FOREIGN KEY ("id_conexao") REFERENCES "public"."conexoes"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."setor_conexao"
    ADD CONSTRAINT "public_setor_conexao_id_empresa_fkey" FOREIGN KEY ("id_empresa") REFERENCES "public"."Empresa"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."setor_conexao"
    ADD CONSTRAINT "public_setor_conexao_id_setor_fkey" FOREIGN KEY ("id_setor") REFERENCES "public"."Setores"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."webhook"
    ADD CONSTRAINT "public_webhook_id_contato_webhook_fkey" FOREIGN KEY ("id_contato_webhook") REFERENCES "public"."contatos"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."webhook"
    ADD CONSTRAINT "public_webhook_id_fkey" FOREIGN KEY ("id") REFERENCES "public"."webhook"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."webhook"
    ADD CONSTRAINT "public_webhook_replyWebhook_fkey" FOREIGN KEY ("replyWebhook") REFERENCES "public"."webhook"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."setores_users"
    ADD CONSTRAINT "setores_users_colab_id_fkey" FOREIGN KEY ("colab_id") REFERENCES "public"."colab_user"("auth_id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."setores_users"
    ADD CONSTRAINT "setores_users_id_empresa_fkey" FOREIGN KEY ("id_empresa") REFERENCES "public"."Empresa"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "public"."setores_users"
    ADD CONSTRAINT "setores_users_setor_id_fkey" FOREIGN KEY ("setor_id") REFERENCES "public"."Setores"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE "public"."Bot" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."Empresa" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."Encerramento_Assunto" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."Encerramento_Tag" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."Respostas_Rapidas" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."Setores" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "acesso_empresa" ON "public"."Encerramento_Assunto" USING (("ref_empresa" = ( SELECT "colab_user"."id_empresa"
   FROM "public"."colab_user"
  WHERE ("colab_user"."auth_id" = "auth"."uid"())))) WITH CHECK (("ref_empresa" = ( SELECT "colab_user"."id_empresa"
   FROM "public"."colab_user"
  WHERE ("colab_user"."auth_id" = "auth"."uid"()))));

CREATE POLICY "acesso_empresa_tag" ON "public"."Encerramento_Tag" USING (("ref_empresa" = ( SELECT "colab_user"."id_empresa"
   FROM "public"."colab_user"
  WHERE ("colab_user"."auth_id" = "auth"."uid"())))) WITH CHECK (("ref_empresa" = ( SELECT "colab_user"."id_empresa"
   FROM "public"."colab_user"
  WHERE ("colab_user"."auth_id" = "auth"."uid"()))));

CREATE POLICY "acesso_geral" ON "public"."Bot" USING (true) WITH CHECK (true);

CREATE POLICY "acesso_geral" ON "public"."colab_user" USING (true) WITH CHECK (true);

CREATE POLICY "acesso_geral" ON "public"."conexoes" USING (true) WITH CHECK (true);

CREATE POLICY "acesso_geral" ON "public"."contatos" USING (true) WITH CHECK (true);

CREATE POLICY "acesso_geral" ON "public"."setores_users" USING (true) WITH CHECK (true);

CREATE POLICY "all" ON "public"."Empresa" USING (true) WITH CHECK (true);

CREATE POLICY "all" ON "public"."Respostas_Rapidas" USING (true) WITH CHECK (true);

CREATE POLICY "all" ON "public"."Setores" USING (true) WITH CHECK (true);

CREATE POLICY "all" ON "public"."conversas" USING (true) WITH CHECK (true);

CREATE POLICY "all" ON "public"."conversas_test" USING (true) WITH CHECK (true);

CREATE POLICY "all" ON "public"."webhook" USING (true) WITH CHECK (true);

CREATE POLICY "all_true" ON "public"."setor_conexao" USING (true);

ALTER TABLE "public"."colab_user" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."conexoes" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."contatos" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."conversas" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."conversas_test" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."setor_conexao" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."setores_users" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."webhook" ENABLE ROW LEVEL SECURITY;

REVOKE USAGE ON SCHEMA "public" FROM PUBLIC;
GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

GRANT ALL ON FUNCTION "public"."atualiza_conversas"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualiza_conversas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualiza_conversas"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualiza_informacoes_colab_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualiza_informacoes_colab_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualiza_informacoes_colab_user"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualiza_nome_contato_conversa"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualiza_nome_contato_conversa"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualiza_nome_contato_conversa"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualiza_ref_empresa_conversa"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualiza_ref_empresa_conversa"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualiza_ref_empresa_conversa"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualiza_setores_nomes"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualiza_setores_nomes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualiza_setores_nomes"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualiza_ultima_mensagem_conversa"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualiza_ultima_mensagem_conversa"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualiza_ultima_mensagem_conversa"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualizar_chat"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_chat"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_chat"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualizar_nome_contato"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_nome_contato"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_nome_contato"() TO "service_role";

GRANT ALL ON FUNCTION "public"."atualizar_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_webhook"() TO "service_role";

GRANT ALL ON FUNCTION "public"."busca_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."busca_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."busca_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_atalho_resposta_rapida"("termo_pesquisa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_atalho_resposta_rapida"("termo_pesquisa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_atalho_resposta_rapida"("termo_pesquisa" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text", "ref_empresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text", "ref_empresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_atalhos_resposta_rapida"("termo_pesquisa" "text", "ref_empresa" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer, "instanciaparam" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer, "instanciaparam" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_conversas_com_webhooks"("refcontatosid" bigint, "refempresaid" bigint, "pagina" integer, "instanciaparam" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_conversas_espera"("p_nome_contato" "text", "p_istransferida" boolean, "p_isforahorario" boolean, "p_isespera" boolean, "p_lista_setores" bigint[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text") TO "service_role";

GRANT ALL ON TABLE "public"."conexoes" TO "anon";
GRANT ALL ON TABLE "public"."conexoes" TO "authenticated";
GRANT ALL ON TABLE "public"."conexoes" TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text", "qref_empresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text", "qref_empresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_nome_conexao"("termo_pesquisa" "text", "qref_empresa" integer) TO "service_role";

GRANT ALL ON TABLE "public"."contatos" TO "anon";
GRANT ALL ON TABLE "public"."contatos" TO "authenticated";
GRANT ALL ON TABLE "public"."contatos" TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text", "qref_empresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text", "qref_empresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato"("termo_pesquisa" "text", "qref_empresa" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text", "qref_empresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text", "qref_empresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_nome_contato_inativo"("termo_pesquisa" "text", "qref_empresa" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_setores_conexao_selecionados"("id_emp" bigint, "id_conn" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_setores_conexao_selecionados"("id_emp" bigint, "id_conn" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_setores_conexao_selecionados"("id_emp" bigint, "id_conn" bigint) TO "service_role";

GRANT ALL ON TABLE "public"."colab_user" TO "anon";
GRANT ALL ON TABLE "public"."colab_user" TO "authenticated";
GRANT ALL ON TABLE "public"."colab_user" TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_username"("termo_pesquisa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_username"("termo_pesquisa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_username"("termo_pesquisa" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_username"("termo_pesquisa" "text", "qref_empresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_username"("termo_pesquisa" "text", "qref_empresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_username"("termo_pesquisa" "text", "qref_empresa" integer) TO "service_role";

GRANT ALL ON TABLE "public"."webhook" TO "anon";
GRANT ALL ON TABLE "public"."webhook" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook" TO "service_role";

GRANT ALL ON FUNCTION "public"."buscar_webhooks"("limite" integer, "qid_api_conversa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."buscar_webhooks"("limite" integer, "qid_api_conversa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscar_webhooks"("limite" integer, "qid_api_conversa" "text") TO "service_role";

GRANT ALL ON TABLE "public"."Bot" TO "anon";
GRANT ALL ON TABLE "public"."Bot" TO "authenticated";
GRANT ALL ON TABLE "public"."Bot" TO "service_role";

GRANT ALL ON FUNCTION "public"."buscarbotporempresa"("refempresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."buscarbotporempresa"("refempresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."buscarbotporempresa"("refempresa" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."contar_conexoes_por_empresa"("refempresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."contar_conexoes_por_empresa"("refempresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."contar_conexoes_por_empresa"("refempresa" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."contar_setores_por_empresa"("refempresa" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."contar_setores_por_empresa"("refempresa" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."contar_setores_por_empresa"("refempresa" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."create_bot_for_new_company"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_bot_for_new_company"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_bot_for_new_company"() TO "service_role";

GRANT ALL ON FUNCTION "public"."extrair_contatos"() TO "anon";
GRANT ALL ON FUNCTION "public"."extrair_contatos"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."extrair_contatos"() TO "service_role";

GRANT ALL ON FUNCTION "public"."extrair_numeros"("input_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."extrair_numeros"("input_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."extrair_numeros"("input_text" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."get_acessible_setor_conexao"("current_auth_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_acessible_setor_conexao"("current_auth_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_acessible_setor_conexao"("current_auth_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."get_colab_user_by_auth_id"("p_auth_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_colab_user_by_auth_id"("p_auth_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_colab_user_by_auth_id"("p_auth_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."get_contact_name_from_conversa"("conversa_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_contact_name_from_conversa"("conversa_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_contact_name_from_conversa"("conversa_id" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."get_conversas_with_contact_names"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_conversas_with_contact_names"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_conversas_with_contact_names"() TO "service_role";

GRANT ALL ON TABLE "public"."Empresa" TO "anon";
GRANT ALL ON TABLE "public"."Empresa" TO "authenticated";
GRANT ALL ON TABLE "public"."Empresa" TO "service_role";

GRANT ALL ON FUNCTION "public"."get_empresa_by_id"("id_empresa" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."get_empresa_by_id"("id_empresa" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_empresa_by_id"("id_empresa" bigint) TO "service_role";

GRANT ALL ON FUNCTION "public"."get_nome_from_conversa"("conversa_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_nome_from_conversa"("conversa_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_nome_from_conversa"("conversa_id" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."get_setores_as_json"("id_empresa_ref" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_setores_as_json"("id_empresa_ref" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_setores_as_json"("id_empresa_ref" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."get_user_setores"("apiauth_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_setores"("apiauth_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_setores"("apiauth_id" "uuid") TO "service_role";

GRANT ALL ON TABLE "public"."conversas" TO "anon";
GRANT ALL ON TABLE "public"."conversas" TO "authenticated";
GRANT ALL ON TABLE "public"."conversas" TO "service_role";

GRANT ALL ON FUNCTION "public"."inatividade_check"() TO "anon";
GRANT ALL ON FUNCTION "public"."inatividade_check"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."inatividade_check"() TO "service_role";

GRANT ALL ON FUNCTION "public"."insere_contato_e_atualiza_conversa"() TO "anon";
GRANT ALL ON FUNCTION "public"."insere_contato_e_atualiza_conversa"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."insere_contato_e_atualiza_conversa"() TO "service_role";

GRANT ALL ON FUNCTION "public"."paginacao_contatos"("limite" integer, "qref_empresa" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."paginacao_contatos"("limite" integer, "qref_empresa" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."paginacao_contatos"("limite" integer, "qref_empresa" bigint) TO "service_role";

GRANT ALL ON FUNCTION "public"."process_chat_data"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_chat_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_chat_data"() TO "service_role";

GRANT ALL ON FUNCTION "public"."process_webhook_data"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_webhook_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_webhook_data"() TO "service_role";

GRANT ALL ON FUNCTION "public"."search_nomecontatos"("p_input" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."search_nomecontatos"("p_input" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_nomecontatos"("p_input" character varying) TO "service_role";

GRANT ALL ON FUNCTION "public"."search_username"("p_input" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."search_username"("p_input" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_username"("p_input" character varying) TO "service_role";

GRANT ALL ON FUNCTION "public"."searchnomecontatos"("search_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."searchnomecontatos"("search_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."searchnomecontatos"("search_text" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."searchnomeconversas"("search_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."searchnomeconversas"("search_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."searchnomeconversas"("search_text" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."searchnomeconversascerta"("search_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."searchnomeconversascerta"("search_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."searchnomeconversascerta"("search_text" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."searchnomeconversasuptade"("search_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."searchnomeconversasuptade"("search_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."searchnomeconversasuptade"("search_text" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."sossego_please"() TO "anon";
GRANT ALL ON FUNCTION "public"."sossego_please"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sossego_please"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_conexao_nomenclatura"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_conexao_nomenclatura"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_conexao_nomenclatura"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_keyconexao_setoreconexao"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_keyconexao_setoreconexao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_keyconexao_setoreconexao"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_nome_conexao_por_nome_setorconexao"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_nome_conexao_por_nome_setorconexao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_nome_conexao_por_nome_setorconexao"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_nome_conexao_setorconexao"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_nome_conexao_setorconexao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_nome_conexao_setorconexao"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_nome_setor_setorconexao"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_nome_setor_setorconexao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_nome_setor_setorconexao"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_responsavel_nome"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_responsavel_nome"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_responsavel_nome"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_setor_nome_conversas"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_setor_nome_conversas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_setor_nome_conversas"() TO "service_role";

GRANT ALL ON FUNCTION "public"."update_status_conversa"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_status_conversa"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_status_conversa"() TO "service_role";

GRANT ALL ON FUNCTION "public"."upload_file_and_insert_url"("file" "bytea", "filename" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upload_file_and_insert_url"("file" "bytea", "filename" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upload_file_and_insert_url"("file" "bytea", "filename" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."verificar_conversa_ativa"("p_id_empresa" bigint, "p_numero_contato" "text", "p_key_instancia" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verificar_conversa_ativa"("p_id_empresa" bigint, "p_numero_contato" "text", "p_key_instancia" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verificar_conversa_ativa"("p_id_empresa" bigint, "p_numero_contato" "text", "p_key_instancia" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."verificar_numero_existente_em_contatos"("numero_a_verificar" character varying, "empresa_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."verificar_numero_existente_em_contatos"("numero_a_verificar" character varying, "empresa_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."verificar_numero_existente_em_contatos"("numero_a_verificar" character varying, "empresa_id" bigint) TO "service_role";

GRANT ALL ON FUNCTION "public"."webhook_per_day_current_week"() TO "anon";
GRANT ALL ON FUNCTION "public"."webhook_per_day_current_week"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."webhook_per_day_current_week"() TO "service_role";

GRANT ALL ON SEQUENCE "public"."Bot_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Bot_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Bot_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."Empresa_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Empresa_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Empresa_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."Encerramento_Assunto" TO "anon";
GRANT ALL ON TABLE "public"."Encerramento_Assunto" TO "authenticated";
GRANT ALL ON TABLE "public"."Encerramento_Assunto" TO "service_role";

GRANT ALL ON SEQUENCE "public"."Encerramento_Assunto_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Encerramento_Assunto_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Encerramento_Assunto_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."Encerramento_Tag" TO "anon";
GRANT ALL ON TABLE "public"."Encerramento_Tag" TO "authenticated";
GRANT ALL ON TABLE "public"."Encerramento_Tag" TO "service_role";

GRANT ALL ON SEQUENCE "public"."Encerramento_Tag_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Encerramento_Tag_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Encerramento_Tag_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."Respostas_Rapidas" TO "anon";
GRANT ALL ON TABLE "public"."Respostas_Rapidas" TO "authenticated";
GRANT ALL ON TABLE "public"."Respostas_Rapidas" TO "service_role";

GRANT ALL ON SEQUENCE "public"."Respostas Rápidas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Respostas Rápidas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Respostas Rápidas_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."Setores" TO "anon";
GRANT ALL ON TABLE "public"."Setores" TO "authenticated";
GRANT ALL ON TABLE "public"."Setores" TO "service_role";

GRANT ALL ON SEQUENCE "public"."Setores_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Setores_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Setores_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."colab user_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."colab user_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."colab user_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."conexoes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."conexoes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."conexoes_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."contatos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."contatos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."contatos_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."contatos_resumo" TO "anon";
GRANT ALL ON TABLE "public"."contatos_resumo" TO "authenticated";
GRANT ALL ON TABLE "public"."contatos_resumo" TO "service_role";

GRANT ALL ON SEQUENCE "public"."conversas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."conversas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."conversas_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."conversas_relatorio" TO "anon";
GRANT ALL ON TABLE "public"."conversas_relatorio" TO "authenticated";
GRANT ALL ON TABLE "public"."conversas_relatorio" TO "service_role";

GRANT ALL ON TABLE "public"."conversas_test" TO "anon";
GRANT ALL ON TABLE "public"."conversas_test" TO "authenticated";
GRANT ALL ON TABLE "public"."conversas_test" TO "service_role";

GRANT ALL ON SEQUENCE "public"."conversas_test_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."conversas_test_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."conversas_test_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."daily_conversations_comparison" TO "anon";
GRANT ALL ON TABLE "public"."daily_conversations_comparison" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_conversations_comparison" TO "service_role";

GRANT ALL ON TABLE "public"."daily_conversations_comparison1" TO "anon";
GRANT ALL ON TABLE "public"."daily_conversations_comparison1" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_conversations_comparison1" TO "service_role";

GRANT ALL ON TABLE "public"."espera_status_stats" TO "anon";
GRANT ALL ON TABLE "public"."espera_status_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."espera_status_stats" TO "service_role";

GRANT ALL ON TABLE "public"."finalized_conversations_this_month" TO "anon";
GRANT ALL ON TABLE "public"."finalized_conversations_this_month" TO "authenticated";
GRANT ALL ON TABLE "public"."finalized_conversations_this_month" TO "service_role";

GRANT ALL ON TABLE "public"."setor_conexao" TO "anon";
GRANT ALL ON TABLE "public"."setor_conexao" TO "authenticated";
GRANT ALL ON TABLE "public"."setor_conexao" TO "service_role";

GRANT ALL ON SEQUENCE "public"."setor_conexao_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."setor_conexao_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."setor_conexao_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."setores_users" TO "anon";
GRANT ALL ON TABLE "public"."setores_users" TO "authenticated";
GRANT ALL ON TABLE "public"."setores_users" TO "service_role";

GRANT ALL ON SEQUENCE "public"."setores_users_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."setores_users_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."setores_users_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."top_setores" TO "anon";
GRANT ALL ON TABLE "public"."top_setores" TO "authenticated";
GRANT ALL ON TABLE "public"."top_setores" TO "service_role";

GRANT ALL ON TABLE "public"."total_conexoes" TO "anon";
GRANT ALL ON TABLE "public"."total_conexoes" TO "authenticated";
GRANT ALL ON TABLE "public"."total_conexoes" TO "service_role";

GRANT ALL ON TABLE "public"."total_setores" TO "anon";
GRANT ALL ON TABLE "public"."total_setores" TO "authenticated";
GRANT ALL ON TABLE "public"."total_setores" TO "service_role";

GRANT ALL ON TABLE "public"."view_chatconversas_espera" TO "anon";
GRANT ALL ON TABLE "public"."view_chatconversas_espera" TO "authenticated";
GRANT ALL ON TABLE "public"."view_chatconversas_espera" TO "service_role";

GRANT ALL ON TABLE "public"."view_colab_user_summary" TO "anon";
GRANT ALL ON TABLE "public"."view_colab_user_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."view_colab_user_summary" TO "service_role";

GRANT ALL ON TABLE "public"."view_contagem_webhook" TO "anon";
GRANT ALL ON TABLE "public"."view_contagem_webhook" TO "authenticated";
GRANT ALL ON TABLE "public"."view_contagem_webhook" TO "service_role";

GRANT ALL ON TABLE "public"."view_conversas_em_atendimento_por_usuario" TO "anon";
GRANT ALL ON TABLE "public"."view_conversas_em_atendimento_por_usuario" TO "authenticated";
GRANT ALL ON TABLE "public"."view_conversas_em_atendimento_por_usuario" TO "service_role";

GRANT ALL ON TABLE "public"."view_conversas_espera_por_usuario" TO "anon";
GRANT ALL ON TABLE "public"."view_conversas_espera_por_usuario" TO "authenticated";
GRANT ALL ON TABLE "public"."view_conversas_espera_por_usuario" TO "service_role";

GRANT ALL ON TABLE "public"."view_conversas_filtradas" TO "anon";
GRANT ALL ON TABLE "public"."view_conversas_filtradas" TO "authenticated";
GRANT ALL ON TABLE "public"."view_conversas_filtradas" TO "service_role";

GRANT ALL ON TABLE "public"."view_conversas_por_empresa" TO "anon";
GRANT ALL ON TABLE "public"."view_conversas_por_empresa" TO "authenticated";
GRANT ALL ON TABLE "public"."view_conversas_por_empresa" TO "service_role";

GRANT ALL ON TABLE "public"."view_conversas_por_usuario" TO "anon";
GRANT ALL ON TABLE "public"."view_conversas_por_usuario" TO "authenticated";
GRANT ALL ON TABLE "public"."view_conversas_por_usuario" TO "service_role";

GRANT ALL ON TABLE "public"."view_setor_colab_count" TO "anon";
GRANT ALL ON TABLE "public"."view_setor_colab_count" TO "authenticated";
GRANT ALL ON TABLE "public"."view_setor_colab_count" TO "service_role";

GRANT ALL ON SEQUENCE "public"."webhook_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."webhook_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."webhook_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."webhook_per_day_current_week" TO "anon";
GRANT ALL ON TABLE "public"."webhook_per_day_current_week" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook_per_day_current_week" TO "service_role";

GRANT ALL ON TABLE "public"."weekly_contact_comparison" TO "anon";
GRANT ALL ON TABLE "public"."weekly_contact_comparison" TO "authenticated";
GRANT ALL ON TABLE "public"."weekly_contact_comparison" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";

RESET ALL;
