# WinHealth

Kit de diagnóstico, reparo e manutenção preventiva para técnicos de suporte
de TI. Roda direto de um pendrive — ou de qualquer pasta local, sem
instalação — com uma interface gráfica própria em PowerShell/WPF.

> **Status:** em desenvolvimento ativo. Uso real em atendimentos de suporte
> técnico em teste no momento.

---

## Demonstração

[▶ Assistir ao vídeo de demonstração](media/demo.mp4)

## O problema

Ferramentas de suporte técnico geralmente assumem acesso total à máquina:
administrador liberado, mídia removível liberada. Na prática, ambientes
corporativos variam muito nisso — política de segurança pode bloquear
dispositivos USB, a conta do usuário pode não ter privilégio de
administrador, o BIOS pode estar travado. A maioria das ferramentas
simplesmente falha nesses cenários, sem explicar por quê.

O WinHealth detecta o nível de acesso disponível em tempo real e se adapta
— inclusive diagnosticando *por que* um pendrive está sendo bloqueado (lê o
identificador de hardware do dispositivo e gera o texto pronto para um
chamado de liberação) e oferecendo um modo alternativo de execução via rede
quando mídia removível não é uma opção.

## Funcionalidades

| Módulo | O que faz |
|---|---|
| **Diagnóstico completo** | Saúde do disco (SMART), memória, temperatura, bateria, histórico de travamentos, erros de hardware, antivírus e atualizações pendentes (inclusive drivers). Gera relatório HTML para o cliente. |
| **Scanner de segurança** | 34 etapas de verificação de processos, registro e itens de inicialização suspeitos, com remoção assistida. |
| **Reparo do Windows** | DISM, SFC e CHKDSK na ordem correta, com ponto de restauração automático antes de começar. |
| **Limpeza** | Remove temporários e cache com prévia de espaço antes de apagar; gerencia itens de inicialização. |
| **Relatório completo** | Pacote de relatórios (bateria, energia, Wi-Fi, drivers) para documentar o atendimento. |
| **Preparar formatação** | Backup de drivers e, com consentimento explícito, backup criptografado da chave do Windows e senhas de Wi-Fi. |
| **Diagnóstico de USB bloqueado** | Identifica a causa do bloqueio e gera o texto do chamado de liberação. |
| **Modo Emergência** | Para máquina que não inicia: boot via WinPE (Ventoy), recupera dump de tela azul, repara o boot, roda SFC/CHKDSK em modo leitura — sem intervenção humana. |

## Arquitetura

- **PowerShell 5.1** puro — roda em qualquer Windows moderno sem instalar nada.
- **WPF/XAML** para a interface gráfica, com a lógica de tela em runspaces
  separados para nunca travar a janela durante uma operação longa (o reparo
  do Windows pode levar até 40 minutos).
- **WMI/CIM** para leitura direta de hardware (SMART, memória, dispositivos).
- **COM interop** com a API interna do Windows Update para checagem real de
  patches e drivers pendentes.
- **Criptografia AES-256-CBC + HMAC-SHA256** (com PBKDF2) para qualquer dado
  sensível opcionalmente salvo.
- **WinPE customizado via Ventoy** para o modo de recuperação offline.

Toda a lógica de interpretação de dados (decidir se um resultado é
"problema" ou "ok") é separada da lógica de coleta (hardware/registro/rede),
o que permite testar a interpretação sem depender de uma máquina real.

## Testes

Mais de 200 testes automatizados, em PowerShell puro, sem dependências
externas — simulam o Windows com dados falsos e rodam em segundos:

```
powershell -NoProfile -File Recursos\tests\Testes.ps1
```

## Licença

Todos os direitos reservados. Este repositório é público para leitura e
avaliação (portfólio técnico) — não para reprodução, redistribuição ou uso
sem autorização. Ver [LICENSE](LICENSE).

## Contato

Gabriel Navarro Bruno — [gabrielnavarrobruno@gmail.com](mailto:gabrielnavarrobruno@gmail.com) · [LinkedIn](https://linkedin.com/in/gabriel-navarro-bruno-75979b246)
