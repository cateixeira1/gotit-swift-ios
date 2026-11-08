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
interna de PDFs, galeria própria de stickers, pastas persistidas, OCR matemático,
SLM integrado ou medições em aparelho físico nesta entrega. Assets antigos são
preservados para undo e não têm coleta de lixo; snapshots completos de desenho e
histórico exigem otimização antes de notas grandes. As miniaturas usam o mesmo
renderizador de blocos, mas ainda precisam de comparação visual em notas complexas.

A suíte cobre isolamento de páginas e histórico. O workflow também compila e
executa testes nativos e smoke tests de navegação/desenho/reabertura em simuladores
para iPad e iPhone, exportando capturas de tela quando a execução as produz.
