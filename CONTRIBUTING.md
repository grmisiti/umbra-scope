# Contribuir para o Umbra Scope

Obrigado por querer ajudar. O Umbra Scope é software livre sob **GPL-3.0-or-later** (ver `LICENSE` e `NOTICE`).

## Como ajudar
- **Problemas e ideias:** abra uma Issue em `github.com/grmisiti/umbra-scope`. Para um bug, diga a versão da app, o macOS,
  a origem da imagem (Resolve, captura ou ficheiro) e, se der, anexe uma amostra pequena.
- **Código:** faça um fork, uma branch por assunto e abra um Pull Request. Leia `README.md` (como compilar e a arquitetura).

## Direitos sobre a contribuição (DCO)
Não pedimos CLA. Pedimos o [Developer Certificate of Origin 1.1](https://developercertificate.org): ao assinar um commit
confirma que escreveu o código, ou tem direito de o enviar, e que aceita que fique sob a licença do projeto. Assine cada
commit com `git commit -s`, que acrescenta a linha:

    Signed-off-by: O Seu Nome <email@exemplo.com>

Pull Requests com commits sem esta linha não são integrados.

## Regras do projeto
- **Sem rede e sem telemetria.** Nenhuma ligação de rede na app; o FFmpeg só abre ficheiros locais.
- **Dependências:** só entram bibliotecas compatíveis com a GPL-3.0 (MIT, BSD, Apache-2.0, MPL-2.0, LGPL, GPL-3.0). Não
  entram CDDL, GPL-2.0-only, "non-commercial" nem código sem licença. Atualize `Resources/Licenses/` e o `README.md`.
- **Plugin OFX:** nunca defina `kOfxPropIcon` nem outras propriedades opcionais no `describe` (o Resolve põe o plugin em
  lista negra).
- **Limites:** frames e imagens até 16384 px de lado e 100 megapixels.
- **Marca:** cor `#8A2BE2` e wordmark UMBRA são o ficheiro vetorial da marca; não se redesenham. Forks usam outro nome e
  outro logo (ver `NOTICE`).
- **Documentação:** se a mudança afeta o utilizador, atualize `CHANGELOG.md` e o `README.md` no mesmo commit.
- Commits separados por assunto, com a mensagem a explicar o porquê.

## Segurança
Se encontrou uma falha, não publique os detalhes numa Issue. Use *Security → Report a vulnerability* no repositório do
GitHub (se a opção estiver ligada) ou abra uma Issue só a pedir um contacto privado, sem descrever a falha.
