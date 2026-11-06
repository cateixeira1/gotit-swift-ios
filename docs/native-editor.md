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
- Formas reconhecidas pela heurística existente viram blocos com texto editável,
  mantendo as proporções. A transformação e a remoção do traço correspondente são
  uma operação de histórico. Desativar reconhecimento preserva o traço livre.
  O reconhecimento geométrico ainda precisa de calibração com manuscritos reais.

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
