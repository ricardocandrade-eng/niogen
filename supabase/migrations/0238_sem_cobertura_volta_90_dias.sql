-- NIOGEN | supabase/migrations/0238_sem_cobertura_volta_90_dias.sql | 16/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11, conversa 128): "Refiz a viabilidade do 633… deu sem viabilidade e não consigo gravar o retorno" →
-- ficha corrigida (commit 1589a50) → "A Saída automática por sem cobertura deve já gravar o retorno de 90 dias sozinha?" — "Sim, grava sozinha".
-- Achado: a Saída automática por sem cobertura (portal sem viabilidade + DFV) punha o lead em Saída "Fachada não atendida" SEM data de
-- retorno — 23 de 24 leads em sem_cobertura sem volta_em; nunca voltavam para a Live, embora o motivo diga "rever em 90 dias".
-- O quê: _saida_limpa_conversa (BEFORE UPDATE, roda depois do _funil_antes) — quando o destino vira 'sem_cobertura' sem Saída manual
-- (saida_em não mudou), grava saida_volta_em = hoje (SP) + config_regras.saida_sem_cobertura_volta_dias (90). Saída manual pela ficha
-- (lead_sair) segue com a data que a pessoa escolheu. Acerto: os leads em sem_cobertura sem retorno ganham a data da saída + 90 dias
-- (nunca antes de amanhã).
-- Regra 20: (1) nenhum estado novo; (2) a Saída por sem cobertura ganha saída automática (volta para a Live na data); (3) só gatilho
-- do banco; (4) fonte: mari_conversas; (5) sem número novo — o "volta para a Live" já existe no v_leads.volta_em.
-- Regra 15: os 90 dias ficam em config_regras, não no código. Nada no mari_principal (o portão não se aplica).
begin;

insert into public.config_regras (chave, valor, descricao, parceiro_id)
select 'saida_sem_cobertura_volta_dias', '90'::jsonb,
       'Saída automática por sem cobertura: em quantos dias o lead volta para a Live (rever a rede). 0238, Ricardo 16/11/2026.', 'dharma'
where not exists (select 1 from public.config_regras where chave = 'saida_sem_cobertura_volta_dias');

create or replace function public._saida_limpa_conversa() returns trigger
language plpgsql set search_path = public as $$
declare v_dias int;
begin
  if new.funil_destino is distinct from old.funil_destino and new.saida_em is not distinct from old.saida_em then
    new.saida_motivo := null; new.saida_sub := null; new.saida_volta_em := null; new.saida_em := null;
    -- 0238: Saída automática por sem cobertura → retorno em N dias (a rede cresce)
    if new.funil_destino = 'sem_cobertura' then
      v_dias := coalesce(nullif(public._bo_cfg('saida_sem_cobertura_volta_dias', '90'::jsonb) #>> '{}', '')::int, 90);
      if v_dias > 0 then
        new.saida_volta_em := (now() at time zone 'America/Sao_Paulo')::date + v_dias;
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- acerto: sem cobertura sem retorno → data da saída + 90 (nunca antes de amanhã)
update public.mari_conversas m
   set saida_volta_em = greatest(
         (coalesce(m.funil_destino_em, now()) at time zone 'America/Sao_Paulo')::date
           + coalesce(nullif(public._bo_cfg('saida_sem_cobertura_volta_dias', '90'::jsonb) #>> '{}', '')::int, 90),
         (now() at time zone 'America/Sao_Paulo')::date + 1)
 where m.funil_destino = 'sem_cobertura' and m.saida_volta_em is null;

commit;
