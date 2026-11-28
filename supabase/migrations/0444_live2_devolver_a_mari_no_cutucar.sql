-- NIOGEN | supabase/migrations/0444_live2_devolver_a_mari_no_cutucar.sql | 28/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 28/11 (caso Vivian): "Vivian eu já respondi. Adiar, o Niogen deixa adiar pra amanhã, mas aí a janela estará fechada.
-- Dar saída não é o caso" → "Sim, os três". O cartão "Cutucar o cliente" (0349: o time respondeu, o cliente ficou calado e a
-- vez voltou ao time para uma cutucada antes de a janela fechar) só tinha Responder, Adiar e Saída. Quem já disse o que tinha a
-- dizer não tinha como tirar a linha sem escrever de novo: "Devolver para a Mari" existia só na ficha.
-- O que muda:
--  (1) live2_fila(): a linha da situação time_agora que é uma CUTUCADA (sem venda, _cutucada_texto preenchido) passa a levar
--      extra = {"cutucar": true};
--  (2) _live2_acoes(): com esse extra, a linha ganha o botão leve "Devolver à Mari" — backoffice_momento('devolver_mari'), a
--      mesma peça do botão da ficha, com confirmação. A Mari retoma com os lembretes dela; a linha sai da fila.
-- Regra 20: (1) vez e prazo: o botão usa a transição que já existe (momento:devolver_mari, andamento → mari_atendendo);
-- (2) ninguém parado: a conversa passa a ter a cadência da Mari; (3) nenhum estado novo, nenhuma tela grava — é a porta;
-- (4) fonte única: a mesma função da ficha; (5) conferência: sem item novo. Regras de ouro 2 e 10: nenhum evento novo.
-- As duas funções são remendadas da versão no ar. Cenário X166. Desempenho: uma chamada a mais de _cutucada_texto por conversa
-- sem venda em time_agora (poucas linhas; a mesma função já roda uma vez para o texto).
begin;

do $mig$
declare
  d text := pg_get_functiondef('public.live2_fila()'::regprocedure);
  p text := E'(then 3 else 2 end,\\r?\\n\\s*)null::jsonb, 2(\\r?\\n\\s*from est e where e\\.vez = ''time'')';
begin
  if position('''cutucar'', true' in d) > 0 then
    raise notice '0444: live2_fila já marca a cutucada';
  else
    if regexp_count(d, p) <> 1 then
      raise exception '0444: não achei o ponto de encaixe em live2_fila';
    end if;
    d := regexp_replace(d, p,
      E'\\1case when e.situacao = ''time_agora'' and e.venda_id is null and e.conversa_id is not null' ||
      E' and public._cutucada_texto(e.conversa_id) is not null then jsonb_build_object(''cutucar'', true) end /* 0444 */, 2\\2');
    execute d;
  end if;
end $mig$;

do $mig$
declare
  d text := pg_get_functiondef('public._live2_acoes(text,text,text,uuid,uuid,text,text,text,jsonb)'::regprocedure);
  p text := E'(''rotulo'', rot, ''principal'', true\\);\\r?\\n\\s*end if;\\r?\\n)(\\s*return a;)';
begin
  if position('0444 (caso Vivian)' in d) > 0 then   -- ('devolver_mari' já existe em outro ramo da função: não serve de marca)
    raise notice '0444: _live2_acoes já tem o Devolver à Mari';
    return;
  end if;
  if regexp_count(d, p) <> 1 then
    raise exception '0444: não achei o ponto de encaixe em _live2_acoes';
  end if;
  d := regexp_replace(d, p, E'\\1' ||
    $ins$    -- 0444 (caso Vivian): na cutucada, quem já respondeu pode devolver a conversa à Mari sem escrever de novo
    if p_fonte = 'situacao' and p_conversa is not null and coalesce((p_extra ->> 'cutucar')::boolean, false) then
      a := a || jsonb_build_object('a', 'rpc', 'fn', 'backoffice_momento', 'rotulo', 'Devolver à Mari', 'leve', true,
                 'confirma', 'Devolver esta conversa para a Mari? Ela retoma com os lembretes dela e a linha sai da fila. Se o cliente responder, é a Mari quem atende.',
                 'args', jsonb_build_object('p_venda', null, 'p_momento', 'devolver_mari', 'p_dados', jsonb_build_object('conversa_id', conv)));
    end if;
$ins$ || E'\\2');
  execute d;
end $mig$;

commit;
