-- NIOGEN | supabase/migrations/0109_textos_live.sql | 10/11/2026 — Claude Code
-- Ricardo (10/11 14h14): "Minha vez" passou a se chamar Live. As telas já trocaram (0107); faltavam os textos que o banco devolve
-- ao operador: avisos "feito" e "aviso" de backoffice_conversa_saida, backoffice_conversa_espera e backoffice_momento ("está na
-- Minha vez") e a mensagem do furo em jornada_furo_registrar. Só texto: a definição viva de cada função é lida e recriada com as
-- trocas (mesma assinatura, mesmo corpo). Idempotente: sem "Minha vez", nada muda.
do $mig$
declare
  f    regprocedure;
  def  text;
  novo text;
  t    text[];
  trocas text[][] := array[
    array['pela Minha vez', 'pelo Live'], array['da Minha vez', 'do Live'], array['na Minha vez', 'no Live'],
    array['Na Minha vez', 'No Live'], array['à Minha vez', 'ao Live'], array[' a Minha vez', ' o Live'],
    array['A Minha vez', 'O Live'], array['Minha vez', 'Live']];
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname = 'public' and p.prosrc like '%Minha vez%'
              and p.proname in ('backoffice_conversa_saida', 'backoffice_conversa_espera', 'backoffice_momento', 'jornada_furo_registrar')
  loop
    def := pg_get_functiondef(f);
    novo := def;
    foreach t slice 1 in array trocas loop
      novo := replace(novo, t[1], t[2]);
    end loop;
    if novo <> def then
      execute novo;
      raise notice 'textos trocados em %', f;
    end if;
  end loop;
end $mig$;
