> Histórico da entrega anterior. O status atual, as mudanças e os limites desta revisão estão em [stage-2-review.md](stage-2-review.md). Teia e equações estão congeladas.

# Editor nativo: páginas e ferramentas

A interface do protótipo usa SwiftUI, UIKit/TextKit e PencilKit, com SF Symbols,
cores semânticas, materiais do sistema e controles nativos. A página continua
branca, inclusive quando os controles acompanham o modo escuro.

- iPad/janelas largas: miniaturas navegáveis à esquerda; texto e régua acima;
  paleta com ícones maiores à direita. A biblioteca de notas pode ser recolhida.
- iPhone/janelas estreitas: páginas e ferramentas em painéis; barra de formatação
  rolável e atalhos inferiores. O conteúdo mantém as dimensões lógicas da página.
- Páginas reais, ordenadas e persistidas, com seleção e adição. As dimensões são
  compartilhadas pela nota (A4 inicialmente); cm/in/px e zoom já são suportados.
- Fonte, tamanho, negrito, itálico, sublinhado, tachado, alinhamento, listas,
  recuo, espaçamento, cores, destaque, links e busca/substituição atuam no texto
  selecionado. Os controles são desabilitados quando nenhum texto está em edição.
- A régua acompanha deslocamento e zoom, usando a unidade da nota. Ainda não
  possui marcadores arrastáveis de margem/recuo.
- Imagem e sticker usam PhotosPicker. Stickers recebem sombra; o recorte e a
  rotação continuam disponíveis no menu contextual. PDF usa o seletor de arquivos,
  preserva o original e mostra uma prévia da primeira página no bloco.
- Caneta, monoline, tinteiro e marcador, além de lápis e borracha, são ferramentas
  reais PencilKit. Cor e espessura são selecionáveis; a faixa efetiva de largura
  respeita os limites nativos de cada ponta. A borracha alterna pixel/traço inteiro.
- Selecionar uma ponta ativa imediatamente o desenho. A primeira marca cria a
  camada de desenho da página; marcas seguintes editam a mesma camada. Dois dedos
  movem o canvas nesse modo. A escrita e as pressões são preservadas em PKDrawing.
- Intenção do traço (07/11/2026). No iPhone o dedo é a caneta: um toque (até 8 pt
  de tela e 0,35 s) não vira tinta nem cria caixa de texto; seleciona o objeto ou
  posiciona o cursor no texto sob o dedo, e em papel vazio não faz nada. Um toque
  logo depois de escrever, ao lado da escrita, é tinta (pingo do i, ponto final).
  Caixas de texto novas nascem no modo cursor. Ao primeiro toque de Apple Pencil
  (ou com o ajuste "Desenhar só com o Apple Pencil"), só o Pencil desenha e o
  dedo rola com um dedo e toca como cursor.
- Formas (07/11/2026, `ShapeRecognition.swift`): fecho convexo e razões de área
  (maior triângulo e maior quadrilátero inscritos, preenchimento do retângulo
  mínimo), que não mudam ao esticar a figura; aceita lados tortos, sobra ou folga
  na ponta, caixa em até 4 traços, caixa e elipse giradas, triângulo para cima,
  baixo e lados, losango. Segurar parado 0,4 s no fim do traço converte na hora e
  com tolerância maior (inclusive linha solta). Sem segurar, a conversão espera
  0,9 s sem novo traço e não ocorre se houver escrita na mesma linha, se o traço
  estiver dentro de um objeto, se o grupo tiver mais de 4 traços ou se a figura
  tiver menos de 40 pt de tela; uma figura convertida assim volta a ser tinta se
  a escrita continuar ao lado em até 3 s (era uma letra, como "o"). A tinta é
  salva antes da conversão: um desfazer devolve o traço original. Medido em
  figuras sintéticas (300 de cada): caixas 299, círculos/elipses 300,
  triângulos 297, nenhuma do tipo errado; 0 de 3.600 letras viraram forma. Falta
  medir com traços reais.
- Ajustes de 08/11/2026, após o terceiro teste em aparelho:
  - Formas lado a lado: um traço logo ao lado de uma figura recém-convertida não a
    desfaz mais na hora. Na pausa seguinte, se esses traços formam (ou começam) outra
    figura, mesmo tosca (reconhecimento com tolerância de "segurar"), a primeira
    fica; só escrita a devolve à tinta. Os vizinhos são avaliados em grupo: uma
    caixa desenhada em vários traços ao lado não conta como escrita.
  - Triângulos de qualquer forma (retângulo, escaleno, apontando para qualquer
    lado): os cantos desenhados são mantidos em `Shape.vertices` (frações do
    quadro); um lado a menos de ~11° da horizontal/vertical fica exato, e um vértice
    perto do meio ou da ponta da base vai para lá. Um triângulo apontando para baixo
    não é mais girado 180° (o texto dentro fica em pé). Canto aberto: três lados
    retos cujo primeiro e último, prolongados, se encontram perto das pontas. Lados
    tortos: o contorno fica perto dos três lados (até 17% do lado), cada canto é uma
    virada real do traço (≥ 34°) e no máximo um lado abaulado para fora (um meio
    disco tem o topo redondo). Medido (300 de cada): forma qualquer 300, para antes
    do início 285, as duas pontas curtas 300, canto aberto entre dois traços 298,
    lados tortos 299, três traços 300; nenhum de outro tipo. Não viraram triângulo
    0 de 3.000 letras de traços retos (Z, N, 4, A, V, W, M, 7, 2) e 13 de 300 meios
    discos (só arcos altos e pontudos). Caixas, círculos e letras mantiveram as
    taxas anteriores.
  - Conectores: um traço que vai de uma figura a outra (reto ou levemente curvo,
    sem voltar; pontas a até 22 pt de tela de cada figura) vira conector reto, mesmo
    curto ou desenhado antes de as figuras converterem: na pausa as figuras
    convertem primeiro e as linhas depois. Os lados de uma caixa em vários traços
    terminam no mesmo grupo e continuam lados.
- Stickers desenhados (08/11/2026, `Stickers.swift`): post-it (`ShapeKind.stickyNote`)
  com caixa de texto dentro, cinco cores de papel (amarelo padrão; menu "Cor do
  post-it"), faixa colada no topo, sombra sob a borda solta e canto inferior direito
  levantado; calendário (`ShapeKind.calendar`, dia em `Shape.date`, "aaaa-mm-dd" no
  calendário do usuário) no estilo do emoji de calendário, com o dia de hoje ao
  inserir; tocar de novo no calendário selecionado (ou "Alterar data…") abre o
  seletor de data. Documentos antigos abrem sem mudança (campos opcionais).
- Teia: uma página embutida mostra todos os seus objetos (ela só existe quando está
  perto da tela) e é redesenhada quando recebe o tamanho real; antes, a primeira
  renderização acontecia com o tamanho provisório da view e podia deixar cartões de
  fora ao voltar de uma nota. A causa exata no aparelho não foi reproduzida aqui.

## Persistência e compatibilidade

O esquema SQLite agora é v3: versões antigas do aplicativo recusam o banco, em
vez de apagar campos de páginas desconhecidos. Notas e snapshots v1/v2 recebem
uma primeira página cujo ID é o ID estável da nota. Blocos antigos sem pageID
pertencem à primeira página; filhos herdam a página do pai. Relações e âncoras não
cruzam páginas. Projeções de página são somente leitura; comandos retornam ao
agregado completo com IDs capturados, sem contaminar outra página durante imports.

O host grava os bytes PencilKit em arquivo atômico identificado por SHA-256 antes
de registrar o asset no SQLite. Cada gesto concluído é um passo de undo/redo.
Traços convertidos em formas são editados como formas (a borracha PencilKit só
apaga traços ainda livres). A página de tinta fica acima dos objetos e não exclui
texto automaticamente; objetos de mídia continuam excluindo texto por padrão.

## Limites restantes

Não há paginação automática do texto, exclusão/reordenação de páginas, edição
interna de PDFs, pastas persistidas, OCR matemático,
SLM integrado ou medições em aparelho físico nesta entrega. Assets antigos são
preservados para undo e não têm coleta de lixo; snapshots completos de desenho e
histórico exigem otimização antes de notas grandes. As miniaturas usam o mesmo
renderizador de blocos, mas ainda precisam de comparação visual em notas complexas.

A suíte cobre isolamento de páginas e histórico. O workflow também compila e
executa testes nativos e smoke tests de navegação/desenho/reabertura em simuladores
para iPad e iPhone, exportando capturas de tela quando a execução as produz.
