-- NIOGEN | supabase/migrations/0286_limpeza_funcoes_orfas.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Reta final, item 7 (limpeza), peça 1 — Ricardo: "Sim, apague as 14" — ficaram 13: mari_limpar_teste é usada pelo portão da Mari (tests/mari_portao.py).
-- Apaga 13 funções que ninguém chama: nenhuma referência em outra função, view, gatilho, cron, restrição, default ou política do banco;
-- nem nas telas (docs/), no n8n (export do repo E os 59 workflows vivos, lidos pela API em 18/11 ~13h), portal, extensão, scripts e
-- edge functions e testes (tests/). Restos do DFV nível 3 (0011), da Mari antiga (0013/0018/0214), do piloto da Fila Vero (0239/0242), do razão (0158),
-- da escada (0156), do OSAB antigo (0168), do parceiro (0117), do push (0215) e do pós-instalação (0176).
-- Sem CASCADE: se algo ainda depender, a migration falha e nada sai.
-- Volta: backup do banco de 18/11 + o arquivo 0286_volta_funcoes_orfas.sql na pasta de backups do PC (as 14 definições da produção, incluída a que ficou).
-- Ficam: mari_limpar_teste (portão da Mari), config_parceiros_degraus_ok (CHECK da config_parceiros) e porta_divergencias_rever (ferramenta manual da 0276).
-- Regra 20: só remove código sem uso (1–5 não se aplicam). Tela, guia e desempenho: sem impacto.
begin;
drop function public._tel_wa(text);
drop function public.dfv_int(text);
drop function public.dfv_num(text);
drop function public.dfv_txt(text);
drop function public.dinheiro_resumo();
drop function public.fila_vero_filtrar();
drop function public.fila_vero_lote(integer);
drop function public.leads_conferencia();
drop function public.mari_liberar(uuid);
drop function public.mari_ultimo_horario(timestamp with time zone, text, interval);
drop function public.osab_importar(text, jsonb);
drop function public.parceiro_oportunidades_resumo(integer);
drop function public.push_medida(integer);
commit;
