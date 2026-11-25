-- NIOGEN | supabase/migrations/0386_abertura_sou_cliente_pergunta.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Caso L-363 (Iranilda, #250, 24/11 21h): veio do anúncio pedindo "mais informações", tocou "🏠 Sou cliente Nio" e recebeu
-- "não consigo ver sua conta nem resolver suporte…", com a Saída "Já é cliente Nio" no mesmo segundo (vez de ninguém, sem retomada).
-- Desde 16/11, 2 de ~10 que tocaram o botão não eram clientes Nio (L-155 tinha Claro e chegou ao CPF; L-146 queria um plano).
-- Ricardo, 24/11: "Somos uma revenda e nosso interesse é exclusivo em vender… Meu receio é descartar venda, mesmo sendo cliente Nio"
-- → "Sim, escreve" (proposta: porta de venda primeiro + 3 botões; Saída só no suporte).
-- O que muda (o código está no 5 · Motor, n8n/mari/n05b_motor.js; aqui só os textos, editáveis sem deploy — regra 15):
--   · o toque em "🏠 Sou cliente Nio" pergunta com 3 botões: 📍 Outro endereço · 🛒 Quero contratar · 🔧 Suporte/fatura;
--     grava dados.abertura_botao = 'cliente_pergunta' — o gatilho mari_conversas_abertura_cliente (0234/0288) NÃO dispara;
--   · só "🔧 Suporte/fatura" grava 'cliente' → o mesmo gatilho dá a Saída "Já é cliente Nio" de sempre (App Nio / 0800);
--   · "Outro endereço" / "Quero contratar" → pedem a rua e o bairro (venda normal; quem barra endereço que já tem Nio é a posse
--     na viabilidade do portal — Ricardo, 23/11).
-- Volta ao de antes sem deploy: abertura_cliente_pergunta = 'nao'.
-- Regra 20: (1) nenhuma situação nova — quem não toca nada fica em "respondeu" com a cadência de sempre (hoje ficava em Saída, sem
-- dono); (2) sem silêncio: a cadência segue para quem não respondeu à pergunta; (3) o estado muda só pelo gatilho/porta de antes;
-- (4) sem fato novo; (5) sem número novo — o retrato já conta ja_cliente_nio.
-- Medição (7 dias): toques em cada botão (mari_turnos.tags ->> 'abertura_botao' in ('cliente_pergunta','cli_outro','cli_contratar',
-- 'cliente')); quantos dos "cliente_pergunta" chegam a CEP e a venda.
begin;

insert into public.config_mari_textos (chave, texto) values
('abertura_cliente_pergunta', 'sim'),
('abertura_botao_cli_outro', $t$📍 Outro endereço$t$),
('abertura_botao_cli_contratar', $t$🛒 Quero contratar$t$),
('abertura_botao_cli_suporte', $t$🔧 Suporte/fatura$t$),
('abertura_resp_cliente_pergunta', $t$Que bom ter você com a gente! 💚

Me conta o que você precisa:

📍 Nio em outro endereço (da família, do trabalho, do comércio): isso é comigo, faço agora.
🛒 Ainda não tem Nio aí? Toca em Quero contratar.
🔧 Fatura, suporte ou mudança de plano: quem resolve é a própria Nio, eu te passo o caminho.$t$),
('abertura_resp_cli_suporte', $t$Entendi! 💚 Fatura, 2ª via, suporte técnico e mudança de plano quem resolve é a própria Nio, e o caminho mais rápido é o App Nio ou o 0800 001 1000.

Aqui é a central de vendas, então não consigo ver a sua conta. Mas se um dia quiser a Nio em outro endereço (da família, do trabalho), é só me chamar aqui 😉$t$),
('abertura_resp_cli_outro', $t$Boa! Vamos levar a Nio pra lá 😊

Me manda a rua e o bairro do endereço novo (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na porta.$t$),
('abertura_resp_cli_contratar', $t$Perfeito! 😊

Tô com o mapa aberto aqui — me manda a rua e o bairro (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na sua porta 😉$t$)
on conflict (chave) do nothing;

commit;
