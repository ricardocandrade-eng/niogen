// NIOGEN | n8n/mari/n05a_conteudo.js — nó "5a · Conteúdo Mari" do mari_principal (04/11/2026)
// SÓ TEXTO. O system prompt vem de mari/prompt_mari_v*.md, embutido aqui pelo n8n/deploy_mari.py
// (trecho entre PROMPT:INICIO e PROMPT:FIM, sem as linhas "# DECISÃO PENDENTE").
// Não edite o texto neste nó: edite o .md, suba a versão e rode o deploy.
const PROMPT_MARI = __PROMPT_MARI__;
const PROMPT_VERSAO = __PROMPT_VERSAO__;
return [{ json: { promptBase: PROMPT_MARI, promptVersao: PROMPT_VERSAO } }];
