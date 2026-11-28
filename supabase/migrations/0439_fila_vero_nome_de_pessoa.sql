-- NIOGEN | supabase/migrations/0439_fila_vero_nome_de_pessoa.sql | 28/11/2026 — Claude Code (Fable 5.2)
-- Pendência "Fila Vero: a mensagem do clique chama empresa pelo 1º nome" (visto no L-183, 18/11: "Oi, Farol!" para
-- Farol Negócios LTDA). A saudação do template nio_fv_clique e o texto pronto do "Chamar por fora" usavam a 1ª palavra do
-- nome da base sem conferir se é nome de gente.
-- O que muda:
--  (1) nome_de_pessoa(text): devolve o 1º nome com inicial maiúscula quando o nome parece de pessoa; senão, nulo. É a mesma
--      regra que o motor da Mari usa na abertura (n05b_motor.js): só letras (palavra com número depois da 1ª é ignorada), 1º nome de 2 a 12 letras, com vogal, sem 3 letras
--      iguais seguidas e sem palavra de empresa (ltda, eireli, comércio, loja, igreja…) em nenhuma parte do nome.
--  (2) fila_vero_clique_resultado(): o parâmetro {{1}} do template passa por nome_de_pessoa — empresa recebe "Oi, tudo bem!",
--      que já era a saída de quem não tem nome.
--  (3) live2_fila(): o texto pronto do "Chamar por fora" ({nome}) usa a mesma função.
-- Não muda: o disparo da oferta (nio_fv_a1/a2), que não leva nome; o nome gravado na conversa (nome_contato segue o da base).
-- Regra 20: (1)–(3) nenhum estado, vez ou prazo muda — só o texto de uma mensagem que já saía; (4) fonte única: fila_vero.nome;
-- (5) conferência: sem item novo (não há estado nem número novo). Regra 15: a lista de palavras fica na função, como já está
-- no motor da Mari; se virar config, as duas mudam juntas. Regra 19: sem tela e sem chamada nova; live2_fila ganha uma chamada
-- de função imutável por cartão "Chamar por fora" (medir na cópia). Regras de ouro 2 e 10: nenhum evento novo na porta.
-- As duas funções são remendadas da versão no ar. Cenário X161.
begin;

create or replace function public.nome_de_pessoa(p text)
returns text language sql immutable set search_path = public as $f$
  with n as (
    -- palavra com número depois da 1ª ("Maria Souza 2", marcação de cadastro) é ignorada; número na 1ª palavra reprova
    select btrim(regexp_replace(btrim(coalesce(p, '')), '\s+\S*\d\S*', '', 'g')) as nc
  ), m as (
    select nc, split_part(nc, ' ', 1) as p1,
           lower(translate(nc, 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
                               'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')) as nn
      from n
  )
  select case when nc ~ '^[A-Za-zÀ-ÿ'' .-]{2,80}$'
               and p1 ~ '^[A-Za-zÀ-ÿ'']{2,12}$'
               and split_part(nn, ' ', 1) ~ '[aeiou]'
               and split_part(nn, ' ', 1) !~ '(.)\1\1'
               and nn !~ '\m(loja|lojas|store|ltda|me|mei|epp|eireli|cia|comercio|comercial|distribuidora|empresa|servicos|atacado|oficina|studio|estudio|salao|bar|lanchonete|restaurante|mercado|supermercado|acougue|padaria|farmacia|drogaria|igreja|escola|negocios|telecom|informatica|imoveis|construtora|construcoes|transportes|industria|associacao|condominio|clinica|hotel|pousada|pecas|materiais|solucoes|consultoria|representacoes|empreendimentos|participacoes)\M'
              then upper(left(p1, 1)) || lower(substr(p1, 2)) end
    from m;
$f$;
comment on function public.nome_de_pessoa(text) is '0439: 1º nome para saudação quando o nome parece de pessoa; nulo para empresa, apelido sem vogal ou nome com número (mesma regra da abertura da Mari). Usada pelo clique da Fila Vero e pelo texto do Chamar por fora.';
grant execute on function public.nome_de_pessoa(text) to authenticated, service_role;

-- ───────────── (2) e (3) remendo das duas funções no ar ─────────────
do $mig$
declare
  alvo text;
  d    text;
  de   text := $a$coalesce(nullif(initcap(lower(split_part(btrim(coalesce(fv.nome, '')), ' ', 1))), ''), 'tudo bem')$a$;
  para text := $b$coalesce(public.nome_de_pessoa(fv.nome), 'tudo bem')$b$;
begin
  foreach alvo in array array['public.fila_vero_clique_resultado(bigint,boolean,text,text)', 'public.live2_fila()'] loop
    d := pg_get_functiondef(alvo::regprocedure);
    if position(para in d) > 0 then
      continue;   -- já remendada: rodar de novo não muda nada
    end if;
    if (length(d) - length(replace(d, de, ''))) / length(de) <> 1 then
      raise exception '0439: não achei (ou achei mais de uma vez) o ponto de encaixe em %', alvo;
    end if;
    execute replace(d, de, para);
  end loop;
end $mig$;

commit;
