# Roteiro de teste manual - WinHealth (janela/GUI)

> Checklist pra você testar a janela do WinHealth de ponta a ponta e saber
> exatamente o que observar em cada parte. Guarda esse arquivo - serve pra
> testar de novo sempre que o Claude mexer em algum módulo (ele deve
> atualizar esta lista quando isso acontecer).

## Como abrir

```
WinHealth.bat gui
```
ou o atalho `WinHealth Janela.bat`. Sem argumento nenhum, o `WinHealth.bat`
continua abrindo o menu de texto de sempre (nada mudou nesse caminho).

## Onde testar cada coisa

- **Diagnóstico, USB**: só leitura, pode testar na sua máquina normal.
- **Limpeza**: seguro na sua máquina (só mexe em temporário/cache/lixeira,
  com travas contra apagar coisa errada) - mas prefira rodar quando não tiver
  nada importante aberto, por via das dúvidas.
- **Scanner**: seguro pra rodar (só verifica; a remoção de itens é sempre
  perguntada dentro da própria janela do scanner).
- **Reparo**: **use a VM de teste**, não a máquina principal (ver seção
  "Ambiente de testes" do `CLAUDE.md`) - roda DISM/SFC/CHKDSK de verdade,
  demora 15-40 min, e embora não deva estragar nada, é a categoria de
  operação que o projeto já decidiu nunca testar na máquina do dia a dia.

---

## 1. Navegação geral da janela

- [v] Abre com a aba **Painel** selecionada, mostrando cartões de resumo
      (máquina, estado de acesso, origem, relatórios) e um cartão por módulo.
- [v] Clicar num cartão do Painel leva pra aba daquele módulo.
- [v] A barra lateral mostra: Painel, Diagnóstico, Scanner, Reparo, Limpeza,
      Relatórios, Formatação, USB, Protegidos - cada um com ícone.
- [v] O topo da janela mostra o nome da máquina e um selo de acesso:
      **verde "Administrador"** se você abriu como admin; **amarelo "Modo
      limitado"** com botão "Reabrir como administrador" se não abriu
      elevado. Clicar nesse botão deve reabrir a janela já elevada (pede UAC)
      **e continuar na mesma aba** em que você estava.
- [v] **Relatórios**, **Formatação** e **Protegidos** ainda abrem em uma
      janela de console separada (botão "Abrir módulo") - isso é esperado,
      ainda não foram migrados pra aba própria.
- [ ] **Novo (28/09/2026): botão "Terminal de Diagnóstico"** no topo da
      janela (ao lado do selo de acesso). Clique nele: abre uma janela
      separada, escura, mostrando um log técnico (não é o relatório do
      cliente) com linhas tipo `2026-09-28 13:16:40 - INFO - ...`. Use o
      botão "Exportar log (.txt)" - deve salvar um arquivo dentro de
      `Relatorios\` e mostrar uma caixa confirmando o caminho. Ideia trazida
      por você (do seu projeto OmniCursorPro) pra ter visibilidade real de
      erros internos - se algo se comportar estranho no futuro, esse log é
      o primeiro lugar pra olhar (ou pra me mandar o conteúdo exportado).

> **Corrigido em 28/09/2026** (você reportou "fica duas guias abertas"):
> achei 2 janelas "WinHealth" abertas de verdade na sua máquina (uma do
> console, outra do Windows Terminal) - o comando que escondia o console
> só escondia o console "clássico", não a janela real do Windows Terminal
> (mesma causa do bug do Scanner). Corrigido; **não consegui reproduzir o
> lançamento real pelo Explorer com minhas próprias ferramentas de teste**
> pra validar 100% - preciso que você confirme. **Teste novo, marque
> abaixo.**
>
> **Atenção, isso é diferente**: se você clicar em "Reabrir como
> administrador" (não simplesmente abrir com `WinHealth Janela.bat`), uma
> janela de console **intencionalmente** fica visível mostrando "Abrindo
> nova janela como administrador... (esta janela aguarda até você fechar a
> outra)" - isso é esperado (ela avisa que vai abrir uma segunda janela e
> some sozinha quando você fechar a admin). Se isso também incomodar,
> me avisa que eu ajusto.

- [ ] Feche TUDO que for "WinHealth" que já estiver aberto (olhe a barra
      de tarefas com cuidado). Dê duplo-clique em `WinHealth Janela.bat`:
      deve abrir **só uma** janela "WinHealth" - nenhuma segunda janela
      (console, Windows Terminal, prompt preto) deve ficar visível ou
      aparecer na barra de tarefas.

## 2. Aba Diagnóstico

- [v] Clicar em **"Rodar diagnóstico"**: o botão desabilita, aparece uma
      barra de progresso real avançando e um texto tipo "Verificando
      (N/M): nome da etapa...". Clicar em "Ver detalhes" mostra o log de
      cada etapa concluída, em ordem.
- [v] **A barra não pode andar sozinha** - se você parar de olhar por alguns
      segundos e voltar, ela só deve ter avançado se uma etapa realmente
      terminou (leva ~15-20s no total; a etapa do Windows Update costuma ser
      a mais lenta).

> **Novo em 28/09/2026** (você achou o "Ver detalhes" meio repetitivo e
> pediu um contador de tempo): agora o texto de cima mostra também "(rodando
> há Xs)", atualizado em tempo real mesmo entre uma etapa e outra - é tempo
> DECORRIDO real, não uma estimativa de quanto falta (isso eu não posso
> mostrar sem inventar um número, já que a etapa do Windows Update varia
> demais). **Teste novo.**

- [ ] Clique em "Rodar diagnóstico" e observe o texto de status: o "(rodando
      há Xs)" deve subir sozinho a cada segundo, mesmo enquanto uma etapa
      lenta (Windows Update) ainda não terminou - não fica parado esperando
      a próxima etapa.
- [v] Ao terminar: aparece um resumo (quantos Problema/Atenção/Ok/Não
      verificado), um cartão com os dados da máquina, e uma seção por
      categoria com os achados coloridos por gravidade.
- [v] Botão **"Gerar relatório para o cliente (HTML)"** abre o navegador com
      o relatório - confirme que os dados batem com o que apareceu na tela.
- [v] Fechar e reabrir a aba (ir pro Painel e voltar) deve manter o último
      resultado na tela, sem precisar rodar de novo.

> **Novo em 28/09/2026** (você perguntou se dava pra checar atualização de
> driver): o diagnóstico agora também verifica isso pelo Windows Update de
> verdade (não é só uma estimativa por data). **Teste novo, marque abaixo.**

- [ ] Depois de rodar o diagnóstico, procure a seção **"Atualizações de
      driver"** no resultado - se a sua máquina tiver algum driver
      desatualizado disponível no Windows Update, aparece um cartão
      **Atenção** por driver ("Driver desatualizado: nome do driver").
      Se estiver tudo em dia, aparece só um item OK.
- [ ] **Se apareceu algum driver desatualizado**: deve aparecer um botão
      **"Abrir Windows Update (Atualizações opcionais)"** logo abaixo do
      botão de gerar relatório - clique nele e confirme que abre a tela de
      Configurações do Windows certa (Windows Update > Atualizações
      opcionais). **Se a máquina estiver em dia** (comum), esse botão não
      deve aparecer - é esperado.
- [ ] Essa checagem não baixa nem instala nada sozinha - só lista e
      direciona pra tela nativa do Windows pra você decidir.

## 3. Aba Scanner

> **Causa raiz real achada em 28/09/2026** (obrigado pela paciência e pelos
> prints - foi o que permitiu achar isso): reparei que você SEMPRE roda o
> WinHealth como Administrador (o selo verde aparece em todos os seus
> prints). Isso importa porque existe uma falha real do PowerShell:
> `Start-Process -Verb RunAs` com um argumento entre aspas **falha
> silenciosamente quando quem chama já está elevado** (o `.bat` nem chega
> a abrir, nem executar a primeira linha) - só funciona quando quem chama
> NÃO está elevado (aí o UAC de verdade aparece e funciona). Como você
> sempre testa já como admin, sempre caiu no caminho quebrado. Confirmei
> isso com 4 testes isolados nesta máquina (reproduzi a falha e depois a
> correção, gerando um relatório real). Corrigido: agora o WinHealth
> verifica se já está admin e só usa o `-Verb RunAs` quando precisa pedir
> elevação de verdade.
>
> **2ª causa achada em 28/09/2026** (seus prints seguintes ajudaram de
> novo): dessa vez o Scanner terminou de verdade (34 etapas, resumo
> executivo na tela), mas a barra do WinHealth ficou travada em "26/34".
> Achei a causa: o nome do arquivo de relatório só tinha precisão de
> MINUTO, então duas execuções no mesmo minuto podiam colidir de nome -
> o WinHealth ficava preso lendo um arquivo "órfão" (de uma tentativa
> anterior) e nunca via o arquivo que realmente completou. Corrigido: o
> nome do arquivo agora inclui segundos, e o WinHealth reavalia qual é o
> arquivo mais recente a cada meio segundo (não só uma vez), então mesmo
> que colida de novo, ele segue o arquivo certo. **Teste de novo,
> marque os itens abaixo.**

- [ ] Clicar em **"Rodar Scanner"**: aparece o pedido de permissão de
      administrador do Windows (UAC). **Aceite** - o Scanner abre a própria
      janela preta (34 etapas) por cima da janela do WinHealth.
- [ ] Enquanto isso, na aba do WinHealth: a barra de progresso deve avançar
      sozinha conforme as etapas REAIS do Scanner terminam (texto tipo
      "Etapa (6/34): DRIVERS..."), sem você precisar fazer nada - é a
      barra lendo o log que o próprio Scanner vai escrevendo.
- [ ] Se o Scanner achar algo suspeito, ele vai perguntar o que remover
      **dentro da própria janela preta dele** (não na janela do WinHealth) -
      responda lá normalmente (ou só dê Enter pra não remover nada).
- [ ] Quando a janela do Scanner fechar sozinha, a aba do WinHealth deve
      mostrar um resumo: "Nenhum sinal suspeito" (verde) ou a contagem de
      alertas de alta/baixa prioridade, com um botão **"Abrir relatório
      completo"** que abre o `.txt` gerado.
- [ ] **Teste também recusar o UAC** (clicar "Não" na permissão): a aba deve
      avisar "Permissão de administrador não concedida" e deixar o botão
      "Rodar Scanner" disponível de novo pra tentar outra vez, sem travar.
- [ ] **Teste também sem o arquivo do Scanner** (renomeie/mova
      temporariamente `Ferramentas\SCANNER ANTI-MINERADOR v4.bat` e rode):
      deve avisar pra colocar o arquivo na pasta certa. Devolva o arquivo
      depois do teste.

## 4. Aba Reparo (idealmente numa VM - ver nota abaixo)

> **Pendência em aberto (não é bug)**: a VM de teste foi descartada
> (27/09/2026, travou 2x no VirtualBox) e ainda não foi substituída. DISM/
> SFC/CHKDSK são ferramentas oficiais de reparo (não formatam nada), então
> rodar direto na sua máquina principal não é do tipo "vai quebrar o
> Windows", mas é a categoria de operação (mexe no sistema, demora 15-40
> min, `CHKDSK` pode pedir reinício) que o projeto decidiu não testar sem
> ambiente isolado. Fica a seu critério decidir: testar na própria máquina
> mesmo, montar um ambiente novo (Hyper-V forçado/outra VM/máquina física),
> ou aceitar rodar sem essa validação prévia por enquanto.

> **Corrigido em 28/09/2026** (você não via onde o ponto de restauração era
> criado): a lógica já criava automaticamente antes de começar, mas nada na
> tela explicava isso antes do clique. Agora tem uma caixa verde visível
> logo acima do botão "Rodar reparo do Windows" explicando exatamente isso.
> **Pode desmarcar os `[x]` abaixo e testar de novo com mais confiança.**

- [v] Sem ser administrador: o botão **"Rodar reparo do Windows"** aparece
      desabilitado, com o aviso "Requer administrador".
- [ ] Antes de clicar, leia a caixa verde que explica o ponto de
      restauração automático - é essa a resposta pra sua dúvida de onde
      criar um "ponto de salvamento" antes de mexer no Windows. **Atualizado
      em 28/09/2026**: agora deixa explícito que dá pra rodar o Reparo mais
      de uma vez no mesmo dia sem problema (o Windows só limita 1 ponto
      NOVO a cada 24h, mas o mais recente que já existe continua servindo
      pra voltar atrás).
- [ ] Como administrador, clicar no botão: primeiro tenta criar um ponto de
      restauração (rápido). Se conseguir, segue direto; se **não** conseguir
      (ex.: já criou um ponto nas últimas 24h), aparece uma caixa mostrando
      a **data/hora real** do ponto mais recente que já existe e perguntando
      se quer continuar mesmo assim - teste os dois caminhos (Sim e Não).
- [ ] Com o reparo rodando: a barra tem 3 posições (DISM, SFC, CHKDSK) e só
      avança quando uma etapa REALMENTE termina - pode ficar parada bastante
      tempo no DISM (às vezes trava visualmente em 20% por minutos, é
      normal, o cronômetro no texto de status continua contando). Abra "Ver
      detalhes" e confira que a última linha muda com o tempo (é a saída
      real do programa, não enfeite).
- [ ] Ao terminar (15-40 min): 4 cartões - ponto de restauração, DISM, SFC,
      CHKDSK - e um banner final ("sem problemas" / "ponto(s) de atenção" /
      "problema(s)", conforme o pior resultado das 3 etapas).
- [ ] Reinicie a máquina/VM depois pra aplicar qualquer reparo feito.

## 5. Aba Limpeza

- [v] Clicar em **"Calcular o que pode ser liberado"**: barra de progresso
      real (uma etapa por alvo: temporários do usuário, do Windows, cache,
      Windows Update), termina em poucos segundos. Aparece a prévia com o
      tamanho de cada alvo (ou "Requer administrador"/"Não existe nesta
      máquina" quando for o caso) e o total estimado.
- [v] Clicar em **"Limpar agora"**: roda de verdade, com barra de progresso
      de novo. Ao terminar, mostra um cartão por alvo (ex.: "liberado" ou
      "X arquivo(s) em uso foram mantidos" se algo estava aberto).
- [v] **Se a Lixeira tiver itens**: aparece uma caixa perguntando "Esvaziar
      Lixeira" ou "Manter Lixeira" **antes** do resumo final - teste os dois
      caminhos (o total só deve incluir o tamanho da Lixeira se você
      escolher Esvaziar).
- [v] **Se a Lixeira estiver vazia**: deve pular direto pro resumo final,
      sem perguntar nada.
- [v] Resumo final mostra a lista de programas de inicialização e o total
      liberado ("Limpeza concluída - X liberados").

> **Corrigido em 28/09/2026** (você testou e "quando eu clico não acontece
> nada"): achei o bug de verdade, testando contra o registro real desta
> máquina - o clique GRAVAVA certo, mas uma peculiaridade do PowerShell
> (um jeito de ler o valor do registro que perde o tipo do dado sem avisar)
> fazia a tela sempre reler "habilitado", não importa o que estivesse
> gravado. Por isso parecia que nada acontecia - na real, o app também
> nunca soube dizer corretamente quais itens já estavam desativados (por
> isso todos os 23 apareciam com "Desativar", mesmo os que já estavam
> desligados no registro há tempo). Corrigido e confirmado com um teste
> automatizado contra o registro de verdade (não um mock). Também separei
> as linhas com uma divisória, porque você reclamou que ficava tudo
> grudado sem dar pra saber qual botão era de qual programa. **Pode
> desmarcar os `[x]` que não deram certo antes e testar de novo.**

- [ ] As linhas da lista devem ter uma linha fina separando um item do
      outro - não deve mais parecer tudo grudado.
- [ ] Confira que os botões batem com a REALIDADE: abra o Gerenciador de
      Tarefas do Windows (aba Inicializar) ANTES de mexer em nada, e
      compare com o que o WinHealth mostra - "Desativar" = habilitado no
      Gerenciador de Tarefas, "Ativar" = desabilitado. Devem bater 100%.
- [ ] Na lista de inicialização (final da Limpeza), clique **"Desativar"**
      num item: o botão deve virar **"Ativar"** na hora, sem precisar
      recalcular nada. Abra o Gerenciador de Tarefas do Windows (aba
      Inicializar) e confirme que aquele item aparece como "Desabilitado".
- [ ] Clique **"Ativar"** de novo no mesmo item: volta pra "Desativar" e o
      Gerenciador de Tarefas mostra "Habilitado" de novo.
- [ ] Clique em **"Desinstalar..."** de qualquer item: deve abrir a tela
      **Configurações do Windows > Apps** (é a lista geral de apps
      instalados, não abre direto no programa específico - é assim mesmo,
      não achamos um jeito confiável de pular direto pro app certo).
      Procure o programa na lista e desinstale manualmente se quiser.
- [ ] Itens que vêm da pasta "Inicializar" **compartilhada entre todos os
      usuários** (raro, mas pode aparecer) devem mostrar só o texto **"Não
      desativável aqui"** no lugar do botão "Desativar" - é esperado, o
      Windows não guarda uma aprovação individual pra esses.
- [ ] Saia da aba (Painel) e volte: os itens que você desativou devem
      continuar mostrando "Ativar" (o estado é lido do registro de
      verdade, não é só da tela).

## 6. Aba USB

- [v] Clicar em **"Verificar USB"** sem nenhum pendrive conectado: o botão
      desabilita brevemente (é rápido, não tem barra de progresso de
      propósito) e o resultado mostra "Nenhum pendrive conectado" na
      conclusão.
- [v] Com um pendrive normal conectado (sem bloqueio): mostra os dados do
      disco (modelo, tamanho, Hardware ID) e a conclusão "Não há sinais de
      bloqueio". Aparece o cartão **"Texto para o chamado"** com um botão
      **"Copiar texto"** - teste colar em algum lugar (bloco de notas) pra
      confirmar que copiou certo.
- [ ] **Se puder testar num ambiente com bloqueio de USB de verdade** (VM
      com a política aplicada via `gpedit.msc`, ver "Ambiente de testes" no
      `CLAUDE.md`): conecte o pendrive, ele não deve aparecer na lista;
      rode a verificação - deve perguntar "Há um pendrive conectado agora?"
      (já que o Windows não o enxerga); responda **Sim** e confira que
      aparece "Pendrive conectado, mas o Windows não o enxerga" com a
      recomendação de abrir chamado.
- [v] Saia da aba (Painel) e volte: o resultado (incluindo a resposta que
      você deu na pergunta) deve continuar na tela, sem perguntar de novo.

---

## O que ainda não foi validado com máquina/hardware real (revisar aqui)

- **Scanner**: as 2 causas raiz achadas (não rodava com admin; GUI travava
  em "26/34" mesmo com o scan completo) foram corrigidas e validadas de
  ponta a ponta com scripts isolados nesta máquina, incluindo reproduzir a
  colisão de nome de arquivo real. Ainda falta você confirmar clicando de
  verdade pela janela (eu testei via script/simulação, não clicando no
  botão nem esperando um UAC real).
- **Janela dupla**: a correção foi validada contra 2 janelas que já estavam
  abertas nesta máquina, mas não contra um lançamento novo pelo Explorer
  (duplo-clique) - preciso que você confirme com `WinHealth Janela.bat`.
- **Terminal de Diagnóstico** (novo, 28/09/2026): o log grava de verdade e
  o hook que captura erro de handler foi validado disparando uma exceção
  real - falta só clicar em "Exportar log" numa tela de verdade.
- **Reparo**: toda a aba foi validada só com dados simulados - falta rodar
  DISM/SFC/CHKDSK de verdade (15-40 min). **Sem VM disponível no momento**
  (ver nota na seção 4 acima) - decida como quer validar isso.
- **USB com bloqueio real**: o cenário "pendrive conectado e invisível" só
  foi testado com dados sintéticos - falta reproduzir com a política de GPO
  ligada. **Também sem VM disponível** - mesma decisão da linha acima.
- **Preparar Formatação / Protegidos** (opções 6 e 8): ainda são só
  console (nunca migradas pra aba própria) - o fluxo de opt-in de chave
  do Windows/senha de Wi-Fi com admin nunca foi testado de ponta a ponta
  de verdade (`Read-Host -AsSecureString` não é automatizável).

Se algum desses testes reais encontrar um comportamento diferente do
descrito aqui, me avisa qual foi (pode ser print de tela) que eu ajusto o
código e esta lista.
