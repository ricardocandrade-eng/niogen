-- NIOGEN | supabase/migrations/0201_dfv_api_config.sql | 14/11/2026 — Claude Code / Opus 5.5
-- Prompt: docs/Prompt_dfv_api_e_rua_do_portal_141126_1935.md (Drive), parte A.
-- A DFV passa a ser consultada pela API do Power BI liberada pelo Rogério (Nio): o mesmo querydata que o operador niogen-dfv
-- repetia de dentro da página, chamado direto pela edge function dfv-consulta, nas 5 regiões da Nio.
-- Esta migration só cria a chave de config. As chaves (X-PowerBI-ResourceKey) e os modelIds de cada região NÃO entram aqui
-- (repo público; quem publica e troca o relatório é a Nio): são gravados pelo CLI em config_regras.dfv_api.regioes.
-- Formato de cada região: {"cod", "ceps": [["00000","19999"], ...], "chave", "model"}.
-- ligado=false → a dfv-consulta volta ao operador da VPS sem deploy.

insert into public.config_regras (chave, valor, descricao, parceiro_id)
values ('dfv_api',
        '{"ligado": true, "cluster": "https://wabi-brazil-south-b-primary-api.analysis.windows.net", "entidade": "BASE_HP_F",
          "timeout_ms": 18000, "cache_s": 600, "janela": 5000, "regioes": []}'::jsonb,
        'DFV ao vivo pela API do Power BI (liberada pelo Rogério, Nio, 14/11/2026). ligado · cluster · entidade · timeout_ms · cache_s · janela · '
        || 'regioes[{cod, ceps[[ini,fim]], chave, model}] — chave/model gravados pelo CLI, nunca no repo. ligado=false volta ao operador da VPS.',
        'dharma')
on conflict (chave) do nothing;
