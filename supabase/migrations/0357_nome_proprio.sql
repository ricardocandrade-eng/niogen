-- NIOGEN | supabase/migrations/0357_nome_proprio.sql | 22/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 22/11 ~13h40: "cria uma regra para normalizar todos os nomes com apenas as iniciais maiúsculas".
-- Os nomes chegam de todo jeito: a Receita (portal) devolve tudo em MAIÚSCULAS, o perfil do WhatsApp vem como o cliente escreveu,
-- a base da Fila Vero é toda em maiúsculas. A regra passa a ser do banco, num lugar só:
--  (1) nome_proprio(texto): iniciais maiúsculas, o resto minúsculo; "de, da, do, das, dos, e, di, du, del, della, van, von" ficam
--      minúsculos no meio do nome; maiúscula também depois de hífen e apóstrofo (Ana-Maria, D'Ávila); siglas de empresa no fim
--      (LTDA, ME, MEI, EPP, S/A, EIRELI, CIA) ficam em maiúsculas; espaços repetidos viram um só. Não mexe em acento nem em emoji.
--  (2) Gatilhos BEFORE em quem guarda nome de cliente — tudo o que gravar (Mari, ficha, extensão, importação) já entra normalizado:
--      vendas.cliente_nome e contato_nome · mari_conversas.nome_contato e dados.nome · indicacoes.indicado_nome · fila_vero.nome.
--      Ficam de fora, de propósito: portal_pedidos.cliente_nome (é o que a Nio mostra — fonte dela), usuarios e parceiros (nome
--      de gente do time, digitado por quem cadastra) e campanhas/anúncios da Meta.
--  (3) Acerto do que já está gravado (19 de 36 vendas, ~55 conversas, a Fila Vero inteira): só o texto do nome muda. O acerto roda
--      com os gatilhos desligados (session_replication_role = replica, só nesta transação), para não mexer em "atualizado em",
--      eventos, Meta ou porta — nada mudou de estado, só a grafia.
-- Regra 20: (1)(2) não toca situação, vez nem prazo; (3) quem normaliza é o banco, em todo caminho de gravação; (4) fonte única
-- da regra: nome_proprio(); (5) nada novo a conferir. Regra 15: vale para qualquer parceiro. Desempenho: sem impacto em tela
-- (a função roda só quando o nome é gravado). Cenário X83. Guia do backoffice: uma linha (o nome aparece normalizado).
begin;

create or replace function public.nome_proprio(p text)
returns text language plpgsql immutable set search_path = public as $function$
declare
  t    text;
  w    text;
  i    int := 0;
  res  text := '';
  pal  text;
  ch   text;
  novo boolean;
  k    int;
  v_mai constant text := 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ';
  v_min constant text := 'áàâãäéèêëíìîïóòôõöúùûüçñ';
begin
  if p is null then return null; end if;
  t := btrim(regexp_replace(p, '\s+', ' ', 'g'));
  if t = '' then return t; end if;
  foreach w in array string_to_array(t, ' ') loop
    i := i + 1;
    if i > 1 and lower(w) in ('de', 'da', 'do', 'das', 'dos', 'e', 'di', 'du', 'del', 'della', 'van', 'von') then
      pal := lower(w);
    elsif i > 1 and upper(w) in ('LTDA', 'LTDA.', 'ME', 'MEI', 'EPP', 'S/A', 'S.A.', 'S.A', 'EIRELI', 'CIA', 'CIA.') then
      pal := upper(w);
    else
      pal := ''; novo := true;
      for k in 1 .. char_length(w) loop
        ch := substr(w, k, 1);
        -- acentos por tabela: não depende do "locale" do banco (num banco em locale C, lower('É') devolve 'É')
        pal := pal || case when novo then translate(upper(ch), v_min, v_mai) else translate(lower(ch), v_mai, v_min) end;
        novo := ch in ('-', '''', '’');
      end loop;
    end if;
    res := res || case when i > 1 then ' ' else '' end || pal;
  end loop;
  return res;
end $function$;
comment on function public.nome_proprio(text) is '0357 (Ricardo, 22/11): a regra única de grafia de nome de cliente — iniciais maiúsculas, partículas minúsculas.';
grant execute on function public.nome_proprio(text) to authenticated, service_role;

-- (2) gatilhos: todo caminho de gravação entra normalizado
create or replace function public._nome_proprio_venda() returns trigger language plpgsql set search_path = public as $function$
begin
  new.cliente_nome := public.nome_proprio(new.cliente_nome);
  new.contato_nome := public.nome_proprio(new.contato_nome);
  return new;
end $function$;
drop trigger if exists vendas_a_nome_proprio on public.vendas;
create trigger vendas_a_nome_proprio before insert or update of cliente_nome, contato_nome on public.vendas
  for each row execute function public._nome_proprio_venda();

create or replace function public._nome_proprio_conversa() returns trigger language plpgsql set search_path = public as $function$
begin
  new.nome_contato := public.nome_proprio(new.nome_contato);
  if new.dados is not null and jsonb_typeof(new.dados) = 'object' and jsonb_typeof(new.dados -> 'nome') = 'string'
     and new.dados ->> 'nome' is distinct from public.nome_proprio(new.dados ->> 'nome') then
    new.dados := jsonb_set(new.dados, '{nome}', to_jsonb(public.nome_proprio(new.dados ->> 'nome')));
  end if;
  return new;
end $function$;
drop trigger if exists mari_conversas_a_nome_proprio on public.mari_conversas;
create trigger mari_conversas_a_nome_proprio before insert or update of nome_contato, dados on public.mari_conversas
  for each row execute function public._nome_proprio_conversa();

create or replace function public._nome_proprio_indicacao() returns trigger language plpgsql set search_path = public as $function$
begin new.indicado_nome := public.nome_proprio(new.indicado_nome); return new; end $function$;
drop trigger if exists indicacoes_a_nome_proprio on public.indicacoes;
create trigger indicacoes_a_nome_proprio before insert or update of indicado_nome on public.indicacoes
  for each row execute function public._nome_proprio_indicacao();

create or replace function public._nome_proprio_fila_vero() returns trigger language plpgsql set search_path = public as $function$
begin new.nome := public.nome_proprio(new.nome); return new; end $function$;
drop trigger if exists fila_vero_a_nome_proprio on public.fila_vero;
create trigger fila_vero_a_nome_proprio before insert or update of nome on public.fila_vero
  for each row execute function public._nome_proprio_fila_vero();

-- (3) acerto do que já está gravado: só a grafia, sem disparar nada
set local session_replication_role = replica;

update public.vendas
   set cliente_nome = public.nome_proprio(cliente_nome), contato_nome = public.nome_proprio(contato_nome)
 where cliente_nome is distinct from public.nome_proprio(cliente_nome) or contato_nome is distinct from public.nome_proprio(contato_nome);

update public.mari_conversas
   set nome_contato = public.nome_proprio(nome_contato),
       dados = case when jsonb_typeof(dados) = 'object' and jsonb_typeof(dados -> 'nome') = 'string'
                    then jsonb_set(dados, '{nome}', to_jsonb(public.nome_proprio(dados ->> 'nome'))) else dados end
 where nome_contato is distinct from public.nome_proprio(nome_contato)
    or (jsonb_typeof(dados) = 'object' and jsonb_typeof(dados -> 'nome') = 'string' and dados ->> 'nome' is distinct from public.nome_proprio(dados ->> 'nome'));

update public.indicacoes set indicado_nome = public.nome_proprio(indicado_nome)
 where indicado_nome is distinct from public.nome_proprio(indicado_nome);

update public.fila_vero set nome = public.nome_proprio(nome)
 where nome is distinct from public.nome_proprio(nome);

set local session_replication_role = origin;

do $$ begin
  if exists (select 1 from public.vendas where cliente_nome is distinct from public.nome_proprio(cliente_nome))
     or exists (select 1 from public.mari_conversas where nome_contato is distinct from public.nome_proprio(nome_contato))
     or exists (select 1 from public.fila_vero where nome is distinct from public.nome_proprio(nome)) then
    raise exception '0357: sobrou nome fora da regra depois do acerto';
  end if;
end $$;

commit;
