-- NIOGEN | supabase/migrations/0336_credito_quem_gravou_na_conversa.sql | 20/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 20/11 (L-207): "Corrige o rótulo: foi a ficha, não a Mari" · "Faz a correção de raiz depois da bateria".
-- O que muda:
--   mari_conversas.credito_origem (criada na 0330) só era preenchida pelo espelho venda → conversa; quem grava direto na conversa
--   (a Mari pelo mari_credito_gravar, a ficha do lead pelo lead_registrar_consulta, a Saída "crédito negado") deixava em branco, e a
--   ficha escrevia "Mari" fixo. Agora um gatilho BEFORE UPDATE grava quem pôs o resultado quando quem gravou não disse:
--     sem usuário (n8n / service_role) → 'mari' · com usuário (admin/BKO na ficha) → 'ficha'.
--   O espelho venda → conversa (0330) continua dizendo a origem dele ('humano'/'sistema') e não é tocado (bandeira credito.espelho).
--   Os já gravados: a origem vem da última consulta registrada em operador_consultas (mesmo resultado, até 5 min de diferença);
--   sem consulta que bata, fica em branco (a ficha mostra só a hora).
-- Regra 20: não muda estado de lead nem aviso ao cliente; só o rótulo de quem gravou. Fonte = quem gravou; a tela só lê.

begin;

alter table public.mari_conversas drop constraint if exists mari_conversas_credito_origem_chk;
alter table public.mari_conversas add constraint mari_conversas_credito_origem_chk
  check (credito_origem is null or credito_origem in ('mari', 'ficha', 'humano', 'sistema', 'operador', 'correcao')) not valid;

create or replace function public._conversa_credito_origem()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('credito.espelho', true), '') = '1' then return new; end if;   -- espelho da venda: ele diz a origem
  if new.credito_origem is distinct from old.credito_origem then return new; end if;           -- quem gravou já disse
  new.credito_origem := case when new.credito_resultado is null then null
                             when auth.uid() is null then 'mari' else 'ficha' end;
  return new;
end $$;
revoke all on function public._conversa_credito_origem() from public, anon, authenticated;

drop trigger if exists mari_conversas_credito_origem on public.mari_conversas;
create trigger mari_conversas_credito_origem before update of credito_resultado on public.mari_conversas
  for each row when (new.credito_resultado is distinct from old.credito_resultado)
  execute function public._conversa_credito_origem();

-- os já gravados (só os em branco): pela última consulta que bate
with q as (
  select c.id, (select case o.origem when 'tela' then 'ficha' else 'mari' end from public.operador_consultas o
                 where o.conversa_id = c.id and o.tipo = 'credito' and o.resultado = c.credito_resultado
                   and abs(extract(epoch from (o.criado_em - c.credito_em))) < 300
                 order by o.criado_em desc limit 1) as orig
    from public.mari_conversas c
   where c.credito_origem is null and c.credito_resultado is not null and c.credito_em is not null)
update public.mari_conversas c set credito_origem = q.orig from q where q.id = c.id and q.orig is not null;

commit;
