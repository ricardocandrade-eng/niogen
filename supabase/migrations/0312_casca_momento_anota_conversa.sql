-- NIOGEN | supabase/migrations/0312_casca_momento_anota_conversa.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- As 4 divergências de 18/11 (porta_sombra 649, 650, 767, 768): o Ricardo clicou Assumir e Devolver para a Mari em dois leads sem
-- venda (Chatwoot 171 às 16h09 e 165 às 19h54). As ações funcionaram (ordens 3909–3914 e 4061–4066 feitas), mas a casca da 0263 em
-- backoffice_momento anotava sempre a conversa vazia (v_c := null) — num lead sem venda a conversa vem em p_dados.conversa_id — e a
-- porta via "(novo)" e "sem regra". Todo Assumir/Devolver de lead sem venda caía na lista; com venda, a situação vinha da venda.
-- O que muda: (1) a casca anota a conversa de p_dados.conversa_id (o núcleo já usava a mesma chave); (2) as 4 anotações antigas
-- ficam marcadas como explicadas por esta migration (superada) e saem de v_porta_divergencias.
-- Ricardo, 19/11: "Revise as 4 divergências de 18/11". Cenário X43.
-- Regra 20: (1) nenhuma tabela nova; (2) não muda o que o botão faz (núcleo intocado); (3) tela sem mudança; (4) desempenho: sem impacto.
begin;

CREATE OR REPLACE FUNCTION public.backoffice_momento(p_venda uuid, p_momento text, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em backoffice_momento__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.backoffice_momento__nucleo(p_venda, p_momento, p_dados); end if;
  perform set_config('porta.dentro', 'backoffice_momento', true);
  v_c := nullif(coalesce(p_dados, '{}'::jsonb) ->> 'conversa_id', '')::uuid;   -- 0312: lead sem venda (antes: sempre null)
  v_a := public._porta_situacao(v_c, p_venda);
  r := public.backoffice_momento__nucleo(p_venda, p_momento, p_dados);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('momento:' || coalesce(p_momento, '') || coalesce(':' || nullif(p_dados ->> 'resultado', ''), ''), 'backoffice_momento', v_c, p_venda, v_a, r);
  return r;
end $function$;

update public.porta_sombra
   set superada = '0312: anotação sem a conversa (casca do backoffice_momento); a ação funcionou'
 where id in (649, 650, 767, 768) and evento in ('momento:assumir', 'momento:devolver_mari')
   and conversa_id is null and venda_id is null and superada is null;

commit;
