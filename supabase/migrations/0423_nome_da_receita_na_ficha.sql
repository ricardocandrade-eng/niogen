-- NIOGEN | supabase/migrations/0423_nome_da_receita_na_ficha.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 26/11 ~20h10: "quando se faz a consulta de crédito no Portal da Nio, vem o nome da Receita. Esse nome é gravado na
-- ficha automaticamente?" — não era: o operador lê o nome (saida.nome_receita) e ele só aparecia na tela Consulta. "Sim, grava."
-- Nasceu do caso L-272 (o nome do lead ficou "Pera Ai" até alguém corrigir à mão): com o nome da Receita gravado quando o
-- crédito roda, o nome ruim ou ausente se corrige sozinho.
-- O que muda:
--   1. conversa_nome_da_receita(conversa, nome, cpf_mascara): a regra, num lugar só.
--        · conversa sem nome, ou com nome PROVISÓRIO (dados.nome_provisorio, o atalho da Mari) → grava o nome da Receita;
--        · nome informado com o MESMO 1º nome ("Júlio" × "JULIO CESAR TEIXEIRA") → completa com o da Receita;
--        · nome informado DIFERENTE (cliente consultando o CPF de um parente, ou o nome que ele usa) → NÃO troca: guarda o da
--          Receita em dados.nome_receita e deixa a decisão para o time (a Mari não passa a chamar o cliente por outro nome);
--        · CPF da consulta diferente do CPF gravado na conversa (pela máscara 123.***.***-45) → não toca em nada.
--      Sempre que grava ou completa: nome_confiavel = true, dados.nome_origem = 'receita', sai o nome_provisorio e fica a linha
--      de sistema na conversa. A grafia é a do gatilho da 0357 (nome_proprio).
--   2. mari_credito_gravar (consulta automática da Mari): chama a regra ANTES de gravar o resultado — a venda que nasce do
--      crédito aprovado (0356) já nasce com o nome certo. Remendo no texto da função da produção; para se não achar o trecho.
--   3. operador_consulta_registrar (tela Consulta): consulta de crédito feita com um lead escolhido e nome_receita no pedido →
--      mesma regra, só para admin/backoffice. Sem lead escolhido, nada muda (a consulta avulsa continua só mostrando).
-- Regra 20: (1) não cria situação, vez nem prazo · (2) não cria estado parado · (3) o nome muda por função do banco, com a linha
-- de sistema dizendo de onde veio · (4) fonte do nome do titular: a Receita, pelo portal da Nio; o que o cliente disse fica
-- quando diverge · (5) sem número novo — conferência não se aplica. Regra 15: sem tabela nova; vale para qualquer parceiro.
-- Regra 5: nada muda no robô — o nome já vinha na resposta do operador. Desempenho: 1 select + 1 update por consulta de crédito.
-- Cenário: tests/fluxos/cenarios/X146_nome_da_receita_na_ficha.sql.
begin;

create or replace function public.conversa_nome_da_receita(p_conversa uuid, p_nome text, p_cpf_mascara text default null)
returns text language plpgsql security definer set search_path = public as $function$
declare
  v      text := public.nome_proprio(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g')));
  d      jsonb;
  atual  text;
  cpf    text;
  prov   boolean;
  ac     constant text := 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  sem    constant text := 'aaaaaeeeeiiiiooooouuuucn';
  p1a    text;
  p1v    text;
begin
  if p_conversa is null or v is null or char_length(v) < 5 or position(' ' in v) = 0 or v ~ '[0-9@]' then return 'ignorou'; end if;
  select coalesce(dados, '{}'::jsonb) into d from public.mari_conversas where id = p_conversa for update;
  if not found then return 'ignorou'; end if;
  cpf := regexp_replace(coalesce(d ->> 'cpf', ''), '\D', '', 'g');
  if char_length(cpf) = 11 and coalesce(p_cpf_mascara, '') ~ '^\d{3}\.\*{3}\.\*{3}-\d{2}$'
     and (left(cpf, 3) <> left(p_cpf_mascara, 3) or right(cpf, 2) <> right(p_cpf_mascara, 2)) then
    return 'outro_cpf';
  end if;
  atual := btrim(coalesce(d ->> 'nome', ''));
  prov := coalesce(d ->> 'nome_provisorio', '') = 'true';
  p1a := translate(lower(split_part(atual, ' ', 1)), ac, sem);
  p1v := translate(lower(split_part(v, ' ', 1)), ac, sem);
  if atual = '' or prov or p1a = p1v then
    if atual = v and not prov and d ->> 'nome_receita' is not distinct from v then return 'igual'; end if;
    update public.mari_conversas
       set dados = (d - 'nome_provisorio') || jsonb_build_object('nome', v, 'nome_receita', v, 'nome_origem', 'receita'),
           nome_confiavel = true
     where id = p_conversa;
    if atual is distinct from v then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (p_conversa, 'sistema', '[nome do titular gravado pela consulta de crédito (Receita)'
              || case when atual <> '' then ' — antes: ' || left(atual, 60) else '' end || ']', false);
    end if;
    return case when atual = '' or prov then 'gravou' else 'completou' end;
  end if;
  if d ->> 'nome_receita' is distinct from v then
    update public.mari_conversas set dados = d || jsonb_build_object('nome_receita', v) where id = p_conversa;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (p_conversa, 'sistema', '[consulta de crédito: o nome na Receita é diferente do informado pelo cliente — conferir o titular na ficha]', false);
  end if;
  return 'diferente';
end $function$;
comment on function public.conversa_nome_da_receita(uuid, text, text) is
  '0423 (Ricardo, 26/11): grava na conversa o nome da Receita lido na consulta de crédito — só se não há nome, se é provisório ou se o 1º nome é o mesmo.';
revoke all on function public.conversa_nome_da_receita(uuid, text, text) from public, anon, authenticated;
grant execute on function public.conversa_nome_da_receita(uuid, text, text) to service_role;

-- ───────────── 2. mari_credito_gravar: remendo no texto da função da produção ─────────────
do $do$
declare
  def  text := pg_get_functiondef('public.mari_credito_gravar(uuid, jsonb)'::regprocedure);
  anc  constant text := '  v := case when v_op in (''aprovado_todas''';
  novo text;
begin
  if position('conversa_nome_da_receita' in def) > 0 then return; end if;
  if position(anc in def) = 0 then raise exception '0423: trecho de mari_credito_gravar não encontrado'; end if;
  novo := replace(def, anc,
    '  -- 0423: o nome da Receita que o portal devolveu vai para a ficha (regra em conversa_nome_da_receita)' || chr(10)
    || '  perform public.conversa_nome_da_receita(p_conversa, p_saida->>''nome_receita'', p_saida->>''cpf_mascara'');' || chr(10)
    || anc);
  execute novo;
end $do$;

-- ───────────── 3. operador_consulta_registrar: a consulta da tela, com lead escolhido ─────────────
create or replace function public.operador_consulta_registrar(p_tipo text, p_dados jsonb)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id bigint;
begin
  if public.meu_perfil() is null then raise exception 'operador_consulta_registrar: sem perfil' using errcode = '42501'; end if;
  if p_tipo not in ('viabilidade', 'dfv', 'duplicidade', 'credito') then raise exception 'tipo inválido'; end if;
  insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, venda_id, cep, numero, complemento, cpf_mascara,
                                         resultado, decisao, detalhe, ms)
  values (p_tipo, 'tela', auth.uid(), nullif(p_dados->>'conversa_id', '')::uuid, nullif(p_dados->>'venda_id', '')::uuid,
          left(p_dados->>'cep', 9), left(p_dados->>'numero', 20), left(p_dados->>'complemento', 60),
          case when p_dados->>'cpf_mascara' ~ '^\d{3}\.\*{3}\.\*{3}-\d{2}$' then p_dados->>'cpf_mascara' end,
          left(p_dados->>'resultado', 60), left(p_dados->>'decisao', 60), p_dados->'detalhe', nullif(p_dados->>'ms', '')::int)
  returning id into v_id;
  -- 0423: crédito consultado com um lead escolhido → o nome da Receita vai para a ficha dele (só admin/backoffice)
  if p_tipo = 'credito' and nullif(p_dados->>'conversa_id', '') is not null and nullif(btrim(p_dados->>'nome_receita'), '') is not null
     and public.meu_perfil() in ('admin', 'backoffice') then
    perform public.conversa_nome_da_receita((p_dados->>'conversa_id')::uuid, p_dados->>'nome_receita', p_dados->>'cpf_mascara');
  end if;
  return v_id;
end $function$;

commit;
