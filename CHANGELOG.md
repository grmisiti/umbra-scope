# Changelog

Registo das alterações visíveis ao utilizador ou ao plugin, da mais recente para a mais antiga. As datas são as do
commit. O estado detalhado e as pendências estão em `progress.md`.

## Não publicado — 31/10/2026

### Alterado
- **Marca:** a paleta da interface passa a ser a da Identidade Umbra: carvão quente (#252420 no fundo, #302F2B nos
  painéis, #3A3934 elevado, #46443F nas linhas), branco-gelo #E6E6E6, secundário #9A9890 e verde de estado #7FCF9D.
  O roxo #8A2BE2 fica para preenchimentos e ícones; o texto pequeno roxo passa a #BD8CF5. Muda em `Palette`, no
  `clearColor` do renderer e em `kInk`/`kPanel` do shader.

## Não publicado — 23/10/2026
A release pública `v0.1` (DMG de 23/10, 18:23) **não inclui** nada desta secção: falta regenerar o DMG e publicar.

### Licença
- O projeto passa a ser **software livre sob GPL-3.0-or-later**: `LICENSE`, `NOTICE` (permissão adicional para o SDK do
  Blackmagic RAW e para o Resolve, e aviso de nome e marca) e `CONTRIBUTING.md` (DCO, sem CLA).
- O LibRaw passa a ser usado pela opção **LGPL 2.1** (a CDDL não é compatível com a GPL); o texto da CDDL saiu de
  `Resources/Licenses/`. A app leva `UmbraScope-GPL-3.0.txt` e `UmbraScope-NOTICE.txt` em `Contents/Resources/Licenses`.

### Adicionado
- **Vectorscope:** *Show 2x Zoom* (`V`, ou a caixa abaixo do título de cada vectorscope) dobra o sinal; o graticule, o anel
  de matiz, a skin line e a percentagem de zoom ficam na escala normal. Independente do zoom do mouse. `--vec2x`. (`93dccfb`)
- **About:** menu Umbra Scope → About Umbra Scope, com a descrição, o aviso de open source em desenvolvimento e os links
  para o repositório e as Issues do GitHub. `--about`. (`76d741d`)
- **Plugin Umbra Link 1.2:** ícone do fantasma (`Contents/Resources/com.grmisiti.umbrascope.UmbraLink.png`). (`76ae6e8`)

### Alterado
- **Marca:** o topo da app mostra o lockup UMBRA / SCOPE do banner do GitHub, e o acento da interface passa do lilás
  #B7A6FF para o roxo Umbra #8A2BE2 (Swift e shader). (`033b92a`)
- **Plugin Umbra Link:** *Max width* começa em 1920 px em nós novos; nós antigos mantêm o valor guardado. (`76ae6e8`)

### Segurança
- Frames, imagens e frames do Link acima de **100 megapixels** são recusados antes de alocar memória. (`4040e0f`)
- O instalador do plugin confere o pacote numa pasta só do root (hash lido ao clicar, sem links simbólicos, assinatura
  intacta) antes de substituir `/Library/OFX/Plugins/UmbraLink.ofx.bundle`. (`4040e0f`)
- Revisão de 23/10 sem vulnerabilidades confirmadas; itens abertos em `progress.md`.

### Corrigido
- O plugin sumia do Resolve: a primeira versão do plugin 1.2 definia `kOfxPropIcon` e isso fazia o Resolve crashar e pôr o
  plugin em lista negra. A propriedade foi retirada; o ícone vem do PNG no bundle. Ver `CLAUDE.md` para a cura da lista negra.

### Documentação
- `README.md`, `progress.md`, `HANDOFF.md`, `CLAUDE.md` e este ficheiro atualizados.

## 0.1 — 22 a 23/10/2026
Primeira versão publicada (`v0.1`, DMG ad-hoc, Apple Silicon, macOS 14+).

- Waveform (Color, RGB, Luma), vectorscope com zoom, False Color, Stops e HML; layouts Single e Comparison com snapshots.
- Fontes: plugin OFX **Umbra Link** (Resolve), placas de captura, vídeo e RAW (FFmpeg LGPL, LibRaw, BRAW SDK).
- LUTs do Resolve aplicados na GPU; análise por área, pontos S1–S4 / R1–R4, marcação scope → imagem.
- Auditoria cartographer (14 fixes, 22/10): tempo de vida dos frames, plugin singleton, socket partilhado, troca de source,
  erros visíveis. Ver `.cartographer/FINAL_REPORT.md` e `progress.md`.
- Segurança de base: sem rede, socket por utilizador (0600), limites de tamanho, FFmpeg só com ficheiros locais.
