-- NIOGEN | supabase/migrations/0188_mari_abertura_pede_cep.sql | 13/11/2026 — Claude Code (sessão "Mari pede o CEP na 1ª resposta")
-- A 1ª resposta da Mari volta a PEDIR O CEP, em texto, no lugar do menu de 3 botões da abertura B2 (0070).
--
-- Por que (medido em 13/11, janela de 14 dias, 108 conversas de WhatsApp — mari_conversas + mari_turnos):
--   · 37 conversas (34 %) nunca deram CEP; sem CEP não há viabilidade, nem qualificada, nem venda.
--   · A 1ª resposta citava o CEP em apenas 35 das 108 (e em 17 das 37 sem CEP): o que saía era a saudação B2
--     "O que você prefere ver primeiro?" + botões — uma mensagem que não pergunta nada.
--   · Dos que tocaram "📍 Ver minha rua" 28/29 deram CEP e dos que tocaram "💰 Ver os planos" 16/18 deram.
--     Dos que tocaram "💬 Falar com alguém": 0 de 11. De quem não tocou botão nenhum: 23 de 50 sem CEP.
--   · Antes da B2 (até 08/11 13h) 15,4 % das conversas ficavam sem CEP (2 de 13); depois da B2, 36,8 % (35 de 95).
--     A amostra de antes é pequena, mas aponta para o mesmo lado que a contagem dos botões.
--
-- O que muda: 'abertura_formato' = 'texto' → a abertura é a saudação + o pedido do CEP e do número, sem botões.
--   O menu continua inteiro na config: 'abertura_formato' = 'botoes' devolve o comportamento de hoje SEM deploy.
--   Os textos de resposta a cada botão ficam (quem já tem a mensagem com botões na tela continua funcionando).
-- O que não muda: cadência (L15/F1/F2 seguem presas a dados.abertura, que continua gravado), v_mari_abertura,
--   handoff de quem pede atendente em texto (o 5b já manda esses para o Claude), nº de mensagens enviadas.
-- Regra 15: nada fixo no código — formato e texto em config_mari_textos.
-- Medição: fração de conversas sem cidade no retrato (por_cidade, balde "sem cidade") — de 33 % para < 15 % em 7 dias.

insert into public.config_mari_textos (chave, texto) values
-- 'texto' (padrão desde 13/11) = saudação + pedido do CEP, em texto. 'botoes' = menu de 3 botões da B2 (0070).
('abertura_formato', 'texto'),
-- {nome} = 1º nome do contato, só se parecer nome de pessoa; sem nome a saudação vira "Oi, tudo bem? 😊".
-- Emoji só na saudação: pedido de dado vai sem emoji (regra de fala da Mari, Ricardo 09/11).
('abertura_corpo_texto', $t$Oi, {nome}, tudo bem? 😊 Aqui é a Mari, da Nio.

Me manda seu CEP e o número da casa que eu já vejo o que tem aí pra você. Se não lembrar o CEP, pode mandar a rua e o bairro.$t$)
on conflict (chave) do nothing;

-- Já existia a chave (reaplicação da migration): garante o valor desta mudança.
update public.config_mari_textos set texto = 'texto' where chave = 'abertura_formato' and texto not in ('texto', 'botoes');

comment on table public.config_mari_textos is
  'Textos fixos das mensagens interativas da Mari (corpo do carrossel, do pagamento, abertura...). '
  'abertura_formato (0188): "texto" = a 1ª resposta pede o CEP; "botoes" = menu de 3 botões da B2 (0070).';
