-- NIOGEN | supabase/migrations/0438_reforco_travou_so_com_endereco.sql | 28/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 28/11: "Sim, aperta". O sinal "travou" da 0437 saiu largo demais: valia para qualquer fala do cliente com 12 letras
-- ou mais. Na primeira leitura em produção (27/11, 4 conversas) só o L-456 tinha dado endereço; as outras eram "já tenho
-- internet" (recusa), "só quero outro ponto" e um áudio sem endereço — e o motivo na tela ("Deu o endereço e a conversa parou
-- antes do CEP") estava errado nas três.
-- O que muda em _live2_reforco(), só no sinal "travou":
--  (1) a fala que conta precisa ter cara de endereço: rua, avenida, travessa, bairro, vila, condomínio, quadra, lote, bloco,
--      apartamento… ou um CEP escrito (reforco_sinais.travou_endereco_regex);
--  (2) fica de fora quando a ÚLTIMA fala do cliente é recusa (_recusa_regex(), a mesma lista da Saída sugerida) ou diz que ele
--      já tem internet / já é cliente / quer outro ponto (reforco_sinais.travou_fora_regex).
-- O resto do sinal é igual: sem CEP, a Mari falou por último, cliente calado há travou_min, não é a 1ª mensagem nem botão.
-- Regra 20: nada muda em etapa, situação, vez ou prazo — Reforço não é tarefa; nenhum estado novo; fonte única: a conversa
-- (mari_turnos); conferência: sem item novo. Regra 15: as duas listas são config. Regras de ouro 2 e 10: nenhum evento novo.
-- A função é remendada da versão no ar. Cenário X160 (o X159 segue valendo).
begin;

update public.config_regras
   set valor = coalesce(valor, '{}'::jsonb) || jsonb_build_object(
         'travou_endereco_regex', '(^|[^[:alnum:]])(rua|avenida|av|travessa|alameda|estrada|rodovia|pra[çc]a|beco|ladeira|vila|bairro|condom[ií]nio|loteamento|quadra|lote|bloco|apartamento|apto?)([^[:alnum:]]|$)|[0-9]{5}-?[0-9]{3}',
         'travou_fora_regex', 'j[aá] (tenho|uso|possuo) (a |o |uma |minha )?(internet|nio|fibra|wi-?fi|plano)|j[aá] sou cliente|outro ponto|ponto (adicional|extra)')
 where chave = 'reforco_sinais' and not (coalesce(valor, '{}'::jsonb) ? 'travou_endereco_regex');

do $mig$
declare
  d  text := pg_get_functiondef('public._live2_reforco()'::regprocedure);
  a  text := $a$and t0.papel = 'lead'))) as s_travou$a$;
  nl text := E'\n';
begin
  if position('travou_endereco_regex' in d) > 0 then
    raise notice '0438: _live2_reforco já exige endereço no sinal travou';
    return;
  end if;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then
    raise exception '0438: não achei o ponto de encaixe em _live2_reforco';
  end if;
  d := replace(d, a,
    $b$and t0.papel = 'lead')$b$ || nl ||
    $b$                            -- 0438: a fala precisa ter cara de endereço (rua, avenida, bairro… ou um CEP escrito)
                            and t.texto ~* coalesce(nullif(p ->> 'travou_endereco_regex', ''), '(^|[^[:alnum:]])(rua|avenida|av|travessa|bairro)([^[:alnum:]]|$)'))
             -- 0438: e a última fala do cliente não pode ser recusa nem "já tenho internet"
             and coalesce(uf.texto, '') !~* public._recusa_regex()
             and coalesce(uf.texto, '') !~* coalesce(nullif(p ->> 'travou_fora_regex', ''), 'j[aá] tenho internet')) as s_travou$b$);
  execute d;
end $mig$;

commit;
