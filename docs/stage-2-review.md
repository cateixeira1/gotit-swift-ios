# Revisão da etapa 2 — 06/11/2026

**Status: aberta.** O commit remoto auditado foi
`fcbf017f33f72253ff865cc3d1d54979973ba6d3`, branch
`codex/stage-2-canvas-engine`, PR #1. A documentação daquele commit já dizia
explicitamente que a etapa 2 não estava encerrada. Esta revisão substitui a
sequência de prioridades dos documentos anteriores. Teia, resolvedor de equações
e ampliação do reconhecimento permanecem congelados.

## Alterações preparadas

1. **Histórico e digitação.** Deltas estruturais bidirecionais; texto usa splice
   por `Character`, preservando emoji e caracteres combinados. Comparações de
   valores Swift evitam serializar blocos inalterados na construção do delta.
   Transações passam a atualizar apenas as linhas modificadas. Um cache de uma
   nota verifica revisão/metadados sob o lock SQLite antes de evitar releituras.
   A UI agrupa digitação consecutiva por posição, bloco, pausa de 1 s e duração
   máxima de 5 s. Colagem, mudança de posição e formatação separam operações.
   Uma operação não textual e um ramo novo após undo também separam grupos.
2. **Desenhos.** Substituição remove o registro da versão anterior quando nenhum
   bloco o utiliza. A coleta considera todas as notas, derivados e estados
   alcançáveis pelo histórico de undo e redo. Arquivos órfãos com mais de 24 h
   são recolhidos em checkpoints ociosos, no máximo uma vez a cada 5 min.
   Migração de bancos antigos poda metadados PencilKit sem referências tanto
   nos estados históricos quanto no estado atual. Arquivos PencilKit continuam
   sendo snapshots completos por gesto, mas a retenção não cresce indefinidamente.
3. **Texto entre páginas.** Novos blocos textuais de raiz em notas recebem um
   identificador de história. TextKit mede glifos, fontes e exclusões, cria
   páginas de continuação, redistribui rich text após edição e transfere a posição
   de edição ao fragmento correspondente. Páginas geradas que ficaram vazias são
   removidas apenas se não contiverem outros objetos. Caixas antigas e textos
   internos de formas continuam independentes; não são migrados silenciosamente.
4. **Views.** Objetos fora do overscan são retirados da hierarquia e seus dados
   descartados; pools limitados a 12 textos e 24 objetos. Foco/IME, seleção e
   arraste ficam fixos até terminar a interação. Imagens têm NSCache de 32 MiB.
   Foram acrescentadas quatro alças de redimensionamento. Os menus de recorte
   continuam numéricos.
5. **Prumo.** Componentes extraídos do leitor no commit
   `5334bbaa274fe4a28c7e3d74b4382922d06804f6` de `cateixeira1/prumo-pdf-ios`,
   com licença MIT preservada em `licenses/Prumo-MIT.txt`. PDF abre em leitor
   com todas as páginas, miniaturas, busca, seleção e marca-texto, além de
   desfazer/refazer dos destaques. Salvar cria um novo asset e uma operação
   reversível na nota; cancelar preserva o original. Não inclui as ferramentas
   de OCR, assinatura, organização, resumo e processamento em lote do Prumo.
6. **Aplicativo.** Host promovido de `Examples/GotItDemo` para `Apps/GotIt`,
   alvo `GotItApp`, com configuração Mac Catalyst. Bundle ID e diretório de dados
   anteriores preservados. Isso ainda não é distribuição assinada/TestFlight.
   O produto SPM `GotItCanvasUI` continua UIKit; macOS utiliza o alvo Catalyst,
   não um editor AppKit.

## Verificação disponível

- 51 testes do núcleo passaram em Swift 6.0.3/Linux após as alterações.
- Regressões novas: 80 edições numa nota com bloco vizinho de 800 mil caracteres
  ocupam um grupo; o bloco vizinho não recebe UPDATE; deltas somados ficam abaixo
  de 80 KB; undo/redo sobrevive ao restart; Unicode; descarte do ramo redo;
  assets permanecem somente enquanto o estado atual/histórico precisa deles.
- Migração de snapshots v1/v2/v3 para deltas, rollback de falhas e concorrência
  entre conexões continuam cobertos. O esquema passa a v5.
- CI do commit `693d1785ce2bb991d20e100dcc258ec828d1aadd` aprovado:
  https://github.com/cateixeira1/gotit-swift-ios/actions/runs/42255842252
- 51 testes do núcleo em Linux/macOS; compilação iOS e Mac Catalyst aprovadas.
- Em cada simulador (iPad e iPhone): 5 testes nativos e 1 teste de interface
  passaram, incluindo paginação, limite de views, PDF multipágina e desenho/reabertura.
- Publicação autorizada pelo usuário e realizada na branch do PR #1.
  O bloqueio anterior de aprovação foi resolvido. A etapa permanece aberta
  pelos critérios funcionais abaixo; aprovação do CI não equivale a conclusão.

## Critérios que impedem o encerramento

- Validar transferência do cursor, IME, teclado e desfazer após reflow no iPad e
  iPhone. **Backspace na fronteira implementado** (commit 4cb299b): na posição 0
  de um fragmento de continuação, apaga o último caractere (emoji/combinação
  inteiros) do fragmento anterior, pula páginas vazias e redistribui; composição
  IME nunca é interceptada. Falta validar em aparelho. **Seleção entre páginas**
  (9fdbee9): continua um `UITextView` por página; numa história com mais de uma
  página, uma seleção vira seleção da história, com destaque próprio em cada
  página e duas alças arrastáveis para outras páginas (rolagem perto das bordas).
  Digitar, apagar, colar, recortar, copiar (texto e RTF), formatar e "Selecionar
  tudo" agem sobre a história inteira, editada como um texto só e redistribuída
  num único desfazer (`StoryEditing`). Testes nativos de edição, desfazer e
  destaque/alças; arrastar as alças só no aparelho. Não afirmar equivalência com Word.
- **Reflow ao mover obstáculos conectado** (commit 7ec3fb3): inserir, remover,
  mover, redimensionar, girar ou mudar o contorno de um objeto, redimensionar a
  caixa da própria história ou mudar o padrão de contorno do canvas redistribui
  as histórias afetadas no mesmo lote (um único desfazer). Traços e digitação não
  disparam. Detecção pura com testes; layout TextKit verificado só por compilação
  e testes de UI existentes, não em aparelho.
- Medir latência e memória em aparelho físico, especialmente histórias longas.
  **Medição no aparelho disponível** (08/11, commit 51c9e7d): menu da nota →
  "Medir desempenho do aparelho", com dados temporários; o usuário copia o
  resultado. O mesmo código roda no CI (simulador, build Debug, não é aparelho):
  antes da paginação incremental, uma tecla custava ~190 ms numa história de 34
  páginas e 30–37 ms numa de 12. **Paginação incremental** (1cd14dd): começa na
  página anterior à editada e para na primeira página que termina onde terminava;
  teste nativo compara 40 edições aleatórias com a paginação completa. Depois
  (b33b14b, simulador Debug): 37 páginas com parágrafos, tecla no fim mediana
  11 ms, no início 16 ms; parágrafo único de 34 páginas, mediana ~30 ms e p95
  ~320 ms. Gravação SQLite por tecla (30 páginas, fora da thread principal) mediana
  ~4 ms; fila de recuperação 0,3 ms; formas 23 ms por traço (eram 107 ms; busca do
  maior quadrilátero passou de O(n⁴) a O(n³)). Faltam os números do aparelho.
  O layout/diff do documento inteiro ainda é percorrido a cada edição (é o que resta
  nos ~11 ms); não há índice espacial incremental. Conexões e a camada PencilKit
  não usam o pool de views de blocos.
- **Fonte do sistema preservada** (a1b9ce3): o texto salvo guardava o nome
  interno da fonte do sistema (".SFUI-…"), que o CoreText não resolve por nome e
  substitui por outra fonte; ao redesenhar, as quebras de linha e de página mudavam
  (página 1 passava de 2.024 para 2.296 caracteres no teste). Agora esse nome não é
  guardado e, em notas existentes, é lido como a fonte do sistema.
- **Histórico limitado por bytes** (commit 072324f): `historyByteLimit`, padrão
  32 MiB por nota, além dos 50 grupos; a entrada mais recente é sempre mantida.
  **Desenho por partes** (9fdbee9): um gesto que só acrescenta traços grava só esses
  traços como mais uma parte (`AssetReference.parts`, até 24); apagar, mover ou
  converter traços, ou a 25.ª parte, grava o desenho inteiro e libera base e partes
  antigas. Notas antigas abrem sem mudança.
- **Fila de recuperação ligada ao app** (0b56315): ver a seção abaixo.
- **IME, colar e desfazer** (testes nativos, 0b56315/1cd14dd): o fim de uma
  composição (tecla morta, kana) passa a ser salvo na hora (antes podia esperar a
  próxima tecla) e relatos repetidos do mesmo texto contam uma vez; digitação
  agrupada e colagem como passo próprio; desfazer/refazer de uma colagem que criou
  páginas. Simulados no simulador; teclado real e IME no aparelho ainda por validar.
- **Recorte com alças** (efef958): "Recortar com alças" usa os quatro cantos para
  aparar ou revelar a imagem sem mover nem reescalar os pixels visíveis, nunca
  além do original; o diálogo numérico continua como "Recorte exato (%)".
- **Imagem dentro de forma** (a5711b2): `imageMask` recorta imagem/adesivo em
  elipse, losango ou triângulo; o contorno de texto segue a máscara.
- **Estilos nomeados** (c2dee63): Título, Subtítulo, Título 1, Título 2, Corpo e
  Citação, com redefinição por nota e estilos próprios. Aplicar age sobre os
  parágrafos da seleção; "Atualizar estilo pela seleção" muda todas as ocorrências
  num único desfazer e preserva formatação manual. Os trechos guardam atributos
  concretos e só uma etiqueta do estilo.
- **Tabelas simples** (9ddeaca, testes nativos ebdc226): células com texto rico,
  inserir/excluir linhas e colunas, linha de cabeçalho, cor de célula e espessura
  da borda; segundo toque edita a célula e a linha cresce para caber o texto.
  O quadro do bloco sempre corresponde à grade (validado). Sem mesclagem nem
  fórmulas, por decisão; ambos podem entrar como campos opcionais.

Verificação desta continuação: 92 testes do núcleo e 7 nativos em Swift 6.0.3/Linux
(toolchain oficial de swift.org) e CI completo aprovado em
https://github.com/cateixeira1/gotit-swift-ios/actions/runs/42298240690

A próxima entrega deve fechar esses critérios, sem retomar Teia/equações antes
que o núcleo de edição tenha sido validado.


## Recuperação de gravações (08/11/2026)

Primeira tentativa (06/11): com a fila ligada ao host, o teste de interface de
desenho falhou 2 de 2 vezes no iPhone e a ligação foi removida (47ed923), sem
causa isolada. Segunda versão (0b56315):

- `PendingEditJournal` virou um log só de acréscimos (uma linha por edição ou por
  confirmação, esvaziado quando nada está pendente). Uma última linha cortada por
  queda é ignorada (sua edição ainda não tinha aparecido); qualquer outra linha
  danificada impede a leitura e o arquivo é preservado.
- O app grava cada edição na fila antes de mostrá-la e a retira depois do commit.
  Diferenças em relação à primeira tentativa: um problema na fila nunca bloqueia a
  edição (um aviso só), a fila em memória comanda a gravação, o documento salvo é
  aplicado antes de qualquer outro `await` e os recibos são apagados numa única
  transação quando a fila esvazia.
- Ao abrir, `replay(into:)` reaplica o que estava pendente usando os recibos: uma
  edição que o SQLite já tinha confirmado não é aplicada duas vezes. O que não puder
  ser aplicado vai para um arquivo à parte (`quarantine`), nunca é descartado.
- Testes: núcleo (reinício, linha cortada, recuperação única com edição já
  confirmada + duas pendentes, quarentena) e interface: com as gravações retidas
  (`--hold-saves`), uma página criada sobrevive ao app ser encerrado. O teste de
  desenho que falhava em 06/11 passou em iPad e iPhone com a fila ligada
  (execuções de 51c9e7d e b33b14b).
- Limite: cobre o app fechado ou encerrado; queda de energia no mesmo instante não
  (sem fsync por tecla). Não testado em aparelho.

O CI reexecuta uma vez um teste que falhe no simulador (`-retry-tests-on-failure`),
depois de uma falha de inicialização do XCUITest ("Failed to get background
assertion"); a primeira falha fica no pacote de resultados.

A estratégia de retomada dos recursos adiados está em [workflow.md](workflow.md).
Teia entra após catálogo/indexação; equações após estabilização da tinta e
validação do reconhecimento, com reavaliação na inteligência local se necessário.

## Quinto teste no aparelho e rodada 2 (08/11/2026)

Correções (a7b5fc7): calendário em folha no iPhone e popover sem adaptação no iPad
(o popover adaptado travava); stickers, post-it, calendário, imagens e PDFs entram no
primeiro espaço livre a partir do canto superior esquerdo (`Placement`, texto vazio
ignorado, sobrepõe só com a página cheia); objetos arrastados para outra página mudam
de página.

Funções novas:

- **Tabelas** (7c7ccf7): toque na primeira célula de uma linha (coluna 1) ou coluna
  (linha 1) seleciona a linha/coluna (faixa azul e alça na borda final para
  estreitar/alargar); toque duplo rápido oferece Duplicar/Excluir; segundo toque
  lento edita a célula. Botões "+" abaixo e à direita da tabela selecionada. Toque
  longo: Nova linha, Nova coluna, Editar célula, submenus Linha n / Coluna n
  (inserir, duplicar, ajustar, excluir) e Aparência. Texto justificado por padrão.
- **Lixeira** (57a3676): deslizar para a esquerda numa nota ou Teia mostra a
  lixeira em vermelho; deslizar até o fim ou tocar apaga. Esquema v7 com a tabela
  `trash`: o documento fica inteiro (conteúdo e histórico) até ser restaurado ou
  apagado para sempre (com confirmação) ou a Lixeira ser esvaziada. Nada é apagado
  automaticamente por tempo.
- **Remover fundo / vetorizar** (4fdf7bf): fotos usam o recorte de sujeito do Vision
  (`VNGenerateForegroundInstanceMaskRequest`, iOS 17); desenhos em papel ou quadro
  branco (ou quando o Vision não encontra sujeito) têm o papel tornado transparente
  (limiar de Otsu). A vetorização traça a linha média de cada traço
  (máscara de tinta, distância chanfrada para a espessura, afinamento Zhang–Suen,
  rastreamento, junção nos cruzamentos, Douglas–Peucker) e cria traços de caneta do
  PencilKit editáveis no lugar da imagem (um passo de desfazer). Escolhido em vez de
  `VNDetectContoursRequest` porque contornos circundam cada linha (viraria duas) e em
  vez de Rembg/Potrace/AutoTrace (Python; Potrace GPL; AutoTrace GPL/LGPL).
  O recorte do Vision não roda no simulador: só o caminho do papel é testado no CI.

## Sexto teste no aparelho (10/11/2026)

Retorno: mover objeto entre páginas mostrava `invalid("Empty command batch")`; remoção de
fundo ruim (borrão); stickers ficavam sob setas e texto; apagar deslizando pedia dois gestos.

Correções (`c54110f`, `e64c535`):
- O aviso vinha da paginação depois da mudança de página: quando o texto não precisa mudar, o
  resultado vazio era aplicado e dava erro. Agora é ignorado.
- Remoção de fundo abre uma prévia: "Objeto da foto" (Vision) ou "Papel ou quadro", com
  controle de sensibilidade; nada muda antes de "Aplicar". O modo papel compara cada pixel com o
  papel ao redor (iluminação desigual), remove pontinhos e uniformiza a cor da tinta. O recorte do
  Vision continua sem teste possível no simulador.
- Camadas: objeto novo ou levado a outra página fica acima dos demais daquela página; objeto
  arrastado fica por cima; filhos logo acima do pai; conectores logo acima do mais alto dos dois
  objetos ligados; "Trazer para a frente" / "Enviar para trás".
- Apagar deslizando: um gesto; passando da metade da linha, vibração leve e apaga ao soltar.
- Ao abrir uma nota o cursor fica no fim do texto (ou numa caixa nova no início da área de
  texto) e o teclado aparece.
- Cartões de nota na Teia em cinza mais escuro com contorno; Teia nova em paisagem.

Funções novas (`0554755`, `f892d53`):
- Área de texto do Word em A4 para notas novas: margens "Normal" do Word em português
  (2,5 cm em cima e embaixo, 3 cm nos lados; área de 15 × 24,7 cm). Fontes consultadas
  divergem (Canaltech fala em 2,5 cm em todos os lados); usei a predefinição "Normal" descrita
  pela Mettzer. Notas antigas mantêm 24 pt; dá para trocar em Opções do canvas.
- Cabeçalho e rodapé (imagem ou primeira página de PDF, texto, altura, alinhamento); o texto da
  nota é repaginado abaixo do cabeçalho e acima do rodapé, num passo de desfazer. Objetos podem
  invadir: enquanto se move ou redimensiona, aparece a linha tracejada cinza e o aviso.
- Numeração de páginas (rodapé/cabeçalho, alinhamento, 1 / Página 1 de N / – 1 –, número
  inicial, sem número na primeira página), também nas miniaturas.
- Ferramentas em grade por grupos com ícones maiores; páginas em grade na folha do iPhone.

CI (f892d53): 143 testes do núcleo, 35 nativos e 5 de interface em iPad e iPhone.

## Início da etapa 3 — desempenho e multimídia (11/11/2026)

- Remoção de fundo aprovada no aparelho; vetorização retirada a pedido do usuário. Pincel de
  retoque (Apagar/Recuperar, tamanho, zoom, desfazer) sobre a máscara do Vision/papel.
- Áudio: gravar, importar, tocar no bloco e transcrever no aparelho (iOS 26 `SpeechAnalyzer`;
  antes, `SFSpeechRecognizer` só no aparelho). Texto numa caixa abaixo do áudio.
- Vídeo: inserir da galeria, primeiro quadro no bloco, tela cheia ao tocar.
- CI e IPA em macos-26 / Xcode 26.6 (escolha do usuário: SpeechAnalyzer + visual Liquid Glass).
  Ajustes para o iOS 26: barra do teclado com ícones (o "Concluir" saía da tela no iPhone),
  conformidades `@preconcurrency`, grade de ferramentas não preguiçosa, mais tempo para testes.
- CI (f2c417b): 36 testes nativos e os testes de interface em iPad e iPhone passando.

### Pedidos de 11/11 (madrugada) e continuação da etapa 3

- Barra acima do teclado rolável (ícones de 44 pt) com "Concluir" fixo.
- Transcrição: áudio convertido para o formato pedido pelo `SpeechAnalyzer` e enviado em
  fluxo; idioma escolhido (padrão pt-BR); aviso quando o texto sai curto demais para a duração.
  Opção de bloco próprio ("Transcrição") ao lado do áudio: direita → esquerda → abaixo → acima.
- Guias de alinhamento ao arrastar (centros e bordas com outros blocos e com a página).
- Logo na tela de abertura; "Color Software" na abertura e no rodapé do menu.
- Papel: caderno, quadriculado e xadrez, na nota toda, numa página ou meia página; tamanho do
  quadrado ajustável (0,3–2 cm), sempre quadrado.
- Escrita vira texto (opcional) na fonte escolhida. SF-Hello não é uma fonte instalável (SVGs
  da Apple, com direitos reservados); Bosk, TrashHand e Desyrel não têm licença de
  distribuição e Malam não tem acentos. Incluídas Caveat (padrão), Patrick Hand, Kalam e Indie
  Flower (OFL); o usuário pode importar fontes próprias.
- Equações escritas à mão: lidas e resolvidas por padrão (resposta em azul ao lado), com chave
  para desligar.
- Folhas abertas a partir de Ferramentas (sticker, gravador, papel, cabeçalho, importação)
  passam a abrir quando a folha de Ferramentas termina de fechar (`onDismiss`), em vez de
  esperar um tempo fixo, que no iOS 26 às vezes não bastava.
- PDF para anotar: cada página do PDF vira uma página da nota com a página do PDF por baixo
  (até 100 por vez), para escrever, desenhar e digitar por cima; a primeira página em branco
  recebe a primeira página do PDF; um só desfazer.

Já existiam e cobrem critérios da etapa 3: views fora da tela não são instanciadas, histórico
com limite de grupos e bytes por nota, coleta de assets que considera o histórico (desfazer e
refazer) e só apaga arquivos com mais de um dia.

## Pedidos de 12/11/2026

- **Transcrição recolhível**: tocar no cabeçalho do bloco de transcrição o recolhe a um quadrado
  8 pt mais largo que a altura do áudio vizinho (60 pt → 68 pt), do lado voltado para o áudio e
  centrado nele quando está ao lado; o texto fica oculto (não é apagado). Tocar no quadrado abre o
  bloco no tamanho anterior, deslocado o quanto o quadrado foi movido. Um passo de desfazer; também
  no menu ("Recolher"/"Abrir"). Campo opcional `Shape.folded` (notas antigas abrem iguais).
- **Texto nas pautas do papel caderno** (nota inteira em papel caderno): cada linha do texto da
  nota ocupa uma faixa de 0,8 cm (duas ou mais para letras grandes, a partir de ~22 pt), sem espaço
  extra entre linhas; o espaço entre parágrafos vira linhas inteiras; a caixa começa numa faixa e
  um toque põe o texto na linha sob o dedo. O TextKit coloca a altura extra de uma linha fixa acima
  das letras, então a base fica sobre a pauta (descendentes tocam a linha). Papel caderno só numa
  página ou meia página não muda o texto (a altura de linha vale para a história inteira).
- **Nota simples**: "Nova nota simples" na lista. Meia folha A4 (A5), papel amarelo pautado, margem
  vermelha, texto começando na segunda linha abaixo da faixa marrom; sem caneta, ferramentas, painel
  de páginas nem menu de inserção; tocar no papel leva o cursor ao fim do texto.
- **Letra de forma**: os traços são redesenhados como linhas pretas de espessura uniforme (a
  textura do lápis ou a largura do marcador não chegam ao Vision), com as letras a ~60 px de altura
  e margem proporcional; idioma fixo (sem detecção automática); se a leitura com correção vier
  insegura (< 0,6), é comparada com uma sem correção e fica a mais confiável.
- **Apagar deslizando**: ao soltar, a linha some num fade de 0,2 s e o espaço fecha animado; ela não
  volta a aparecer enquanto a nota vai para a Lixeira (antes voltava por um instante).

### Etapa 3: derivados e importação de mídia grande

- **Derivados** (`DerivedImages`): fotos grandes (> 2048 px ou > 1,5 MB), o primeiro quadro de
  vídeos e a primeira página de PDFs são mostrados a partir de cópias menores em Caches, criadas na
  primeira vez. Antes, cada falta no cache decodificava o original (HEIC de 12 MP, PDF inteiro lido
  na memória, gerador de quadros do vídeo) na thread principal. As cópias não fazem parte da nota
  (nem do desfazer): o asset original por hash continua a única fonte, elas são refeitas quando
  faltam e o iOS pode apagá-las. A limpeza de assets órfãos apaga também as cópias. Cache de imagens
  decodificadas passou de 32 para 64 MiB.
- **Áudio e vídeo importados em pedaços**: o hash SHA-256 é calculado lendo blocos de 1 MB e o
  arquivo é copiado (fora da thread principal), em vez de carregar o vídeo inteiro na memória.
- Escolha registrada: derivados em cache e não em `Asset.derivatives` (que entraria no histórico
  de desfazer e exigiria migrar notas antigas). Compactar vídeos ao importar fica para decidir com o
  usuário (perda de qualidade do original).

CI (`327e5fe`): 151 testes do núcleo (Linux e macOS), 48 nativos e os de interface em iPad e
iPhone aprovados (https://github.com/cateixeira1/gotit-swift-ios/actions/runs/43335034763). Entre
os nativos novos: texto na pauta, letras grandes em duas faixas, nota simples, recolher/abrir a
transcrição, "LEITE" em letra de forma lido pelo Vision, derivados e importação em pedaços. Na
execução de push do mesmo commit, um teste de interface do iPad expirou ao abrir o app no simulador
(passou na outra execução). Falta validar no aparelho.

## Pedidos de 12/11/2026 (noite)

- **Reduzir vídeo, por escolha do usuário**: no menu do vídeo, "Reduzir tamanho…" mostra o tamanho
  atual e oferece Alta (até 1080p, HEVC quando o aparelho codifica) ou Média (até 720p). A cópia
  menor substitui o vídeo num passo de desfazer; se não economizar ao menos 10 %, nada muda e o
  app avisa. Em Ferramentas › "Vídeos ao inserir" o padrão é Original; dá para escolher inserir já
  reduzido. O original continua guardado enquanto o histórico de desfazer precisar dele.

## Início da etapa 4 — catálogo: pastas

- Esquema v8: tabelas `folders` (aninhadas) e `document_folders`. Como a Lixeira, arquivar uma nota
  numa pasta fica fora da nota: não muda a revisão nem entra no desfazer.
- Lista: a pasta aberta (com "Voltar para…"), suas subpastas (com contagem) e as notas e Teias dela;
  notas novas entram na pasta aberta, que é lembrada ao reabrir o app. Menu de nota e de pasta:
  "Mover para" (início ou qualquer pasta, recuadas por nível); pasta: Renomear e Apagar.
- Apagar uma pasta nunca apaga notas: o conteúdo sobe para a pasta de cima. Uma pasta não vai para
  dentro dela mesma nem de uma subpasta. Nota na Lixeira mantém a pasta e volta para ela.
- Próximos itens da etapa 4: miniaturas por revisão, referências estáveis entre notas e indexação
  incremental para a busca.

CI (`c11b527`): 152 testes do núcleo, 50 nativos e os de interface em iPad e iPhone aprovados
(https://github.com/cateixeira1/gotit-swift-ios/actions/runs/43343445083), incluindo a redução de um
vídeo 1080p para 720p e as pastas (persistência e lista). Falta validar no aparelho.

## Etapa 4 — busca (13/11/2026)

- Esquema v9: índice FTS5 (`search_text`, tokenizador `unicode61 remove_diacritics 2`): acentos e
  maiúsculas não contam. Entram título, texto da nota, caixas de texto, post-its, transcrições,
  células de tabela e legendas de imagens, PDFs, áudios e vídeos. Escrita à mão só depois de
  convertida em texto.
- **Indexação incremental**: cada edição atualiza, na mesma transação SQLite, só os blocos cujo
  texto mudou; desfazer e refazer também. Notas apagadas para sempre saem do índice; as da Lixeira
  ficam fora dos resultados. O índice é construído a partir das notas na primeira busca (bancos
  anteriores) e de novo se `SearchText.indexVersion` mudar.
- **Busca na lista** ("Buscar nas notas"): cada palavra precisa aparecer e pode ser o começo de uma
  palavra maior ("proc" acha "processo"); procura em todas as pastas; uma linha por nota, com o
  trecho e as palavras em destaque, a pasta e quantos lugares combinaram. Tocar abre a nota na
  página do trecho, com a palavra selecionada.
- Próximos itens da etapa 4: miniaturas por revisão e referências estáveis entre notas; busca
  espacial e por significado (embeddings) depois.

CI (`e77434f`): 155 testes do núcleo (Linux e macOS, com FTS5), 51 nativos e os de interface em
iPad e iPhone aprovados (https://github.com/cateixeira1/gotit-swift-ios/actions/runs/43354628495).
Falta validar no aparelho.

## Etapa 4 — miniaturas por revisão e ligações entre notas (13/11/2026)

- **Miniaturas por revisão** (`PreviewCache`): a miniatura de cada nota fica em Caches com o número
  da revisão. Ao abrir o app ou voltar à lista, só é aberta e desenhada a nota que mudou desde a
  última miniatura (antes, todas as notas eram carregadas do SQLite e desenhadas a cada início); a
  nota aberta é desenhada da memória. A revisão anterior é apagada ao gravar a nova, e as de uma nota
  apagada para sempre também.
- **Ligações entre notas**: no menu do texto, "Ligar a outra nota…" abre a lista de notas e Teias
  (busca por título); o texto selecionado vira link, ou, sem seleção, o título da nota é escrito como
  link. O link guarda o identificador da nota (`gotit://nota/<id>`), então continua valendo se ela
  mudar de nome ou de pasta. Num texto em edição links não abrem com um toque: o menu de edição sobre
  o link mostra "Abrir “título”". Voltar retorna à nota de origem.
- **Citada em…** (menu da nota): notas e Teias que apontam para ela (links no texto, células de
  tabela e cartões de Teia), mantidas na tabela `note_links` (esquema v10) na mesma transação de cada
  edição, desfazer e refazer, junto com o índice de busca (versão 2, reconstruído uma vez).
