-- NIOGEN | 0118_dominio_proprio_niogen.sql | 10/11/2026 — imagens do carrossel da Mari passam para niogen.dharmatelecom.com.br
update public.config_mari_carrossel
   set imagem_url = replace(imagem_url, 'https://ricardocandrade-eng.github.io/niogen/', 'https://niogen.dharmatelecom.com.br/')
 where imagem_url like 'https://ricardocandrade-eng.github.io/niogen/%';
