// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.
// @ts-ignore
import * as postgres from 'https://deno.land/x/postgres@v0.17.0/mod.ts'



// @ts-ignore
const databaseUrl = Deno.env.get('SUPABASE_DB_URL')!
const pool = new postgres.Pool(databaseUrl, 3, true)
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// @ts-ignore
Deno.serve(async (req) => {
  const payload = await req.json()
  const payJsonStr = JSON.stringify(payload, null, 2);
  const payJson = JSON.parse(payJsonStr)
  const idApi = payJson['record']['id_api_conversa']
  const msg = payJson['record']['mensagem']
  const record = payJson['record']
  const instanceKey = payJson['record']['instance_key']
  const numero = payJson['record']['contatos']

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const connection = await pool.connect();
    try {
      const resultConversa = await connection.queryObject`SELECT * FROM "conversas" WHERE id_api = ${idApi} and numero_contato = ${numero}`
      console.log({idApi, numero})
      const conversa = resultConversa.rows
      const bodyCon = JSON.stringify(conversa, (key, value) => (typeof value === 'bigint' ? value.toString() : value), 2)
      const json = JSON.parse(bodyCon)
      console.log('jsonCon:', json);
      const contato = json[0]['numero_contato']
      const refEmpresa = json[0]['ref_empresa']
      const idConversa = json[0]['id']
      const protocolo = json[0]['Protocolo']
      const date = new Date()
      const oi = Object.keys(json).length !== 0
      console.log({instanceKey, contato, refEmpresa, idConversa, oi})
      
      // Checa se há conversas com o id
      if (Object.keys(json).length !== 0) {
        // Obtem o bot
        const result = await connection.queryObject`SELECT * FROM "Bot" WHERE id_empresa = ${refEmpresa}`
        const bot = result.rows;
        const body = JSON.stringify(bot, (key, value) => (typeof value === 'bigint' ? value.toString() : value), 2)
        const jsonBot = JSON.parse(body)
        // Checa se a conversa é de um bot
        if (json[0]['Status'] == 'Bot') {

          // Verifica se o bot está disponível
          if (jsonBot[0]['ativo'] == false) {
            const setor = jsonBot[0]['setor_transferido_automaticamente']
            const espera = "Espera"
            await connection.queryObject`UPDATE "conversas" SET "Status" = ${espera}, "isespera" = ${true}, "isforahorario" = ${false}, id_setor = ${setor} where id = ${idConversa}`
            await atendimentoTrasnferido(contato, setor, connection)
            
            return new Response('ok', { headers: corsHeaders })
          }


          const diaBusca = date.getDay() === 6 ? 1 : date.getDay() + 1
          const dia = jsonBot[0]['funcionamento']['dias'][`${diaBusca}`]
          if (dia != undefined && dia != null && Object.keys(dia).length !== 0) {
            if (dia['ativo'] == false) {
              const setor = jsonBot[0]['setor_transferido_automaticamente']
              const espera = "Espera"
              await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${jsonBot[0]['msg_botFora']}, ${idApi}, true, NOW(), true, true)`
              await connection.queryObject`UPDATE "conversas" SET isespera = false, isforahorario = true, "Status" = ${espera}, id_setor = ${setor} where id = ${idConversa}`
              updateDb(instanceKey, contato, jsonBot[0]['msg_botFora'])
              await atendimentoTrasnferido(contato, setor, connection)
              return new Response('ok', { headers: corsHeaders })
            }

            if (horaEstaNoIntervalo(dia['inicio'], dia['fim']) == false) {
              const setor = jsonBot[0]['setor_transferido_automaticamente']
              const espera = "Espera"
              await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${jsonBot[0]['msg_botFora']}, ${idApi}, true, NOW(), true, true)`
              await connection.queryObject`UPDATE "conversas" SET isespera = ${false}, isforahorario = ${true}, "Status" = ${espera}, id_setor = ${setor} where id = ${idConversa}`
              updateDb(instanceKey, contato, jsonBot[0]['msg_botFora'])
              await atendimentoTrasnferido(contato, setor, connection)
              return new Response('ok', { headers: corsHeaders })
            }
          } else {
            const setor = jsonBot[0]['setor_transferido_automaticamente']
            const espera = "Espera"
            await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${jsonBot[0]['msg_botFora']}, ${idApi}, true, NOW(), true, true)`
            await connection.queryObject`UPDATE "conversas" SET isespera = ${false}, isforahorario = ${true}, "Status" = ${espera}, id_setor = ${setor} where id = ${idConversa}`
            updateDb(instanceKey, contato, jsonBot[0]['msg_botFora'])
            await atendimentoTrasnferido(contato, setor, connection)
            return new Response('ok', { headers: corsHeaders })
          }

          // Obtem os webhooks da conversa
          const hooksInConversa = await connection.queryObject`SELECT * FROM "webhook" WHERE id_api_conversa = ${idApi}`
          const hooks = hooksInConversa.rows
          const bodyHooks = JSON.stringify(hooks, (key, value) => (typeof value === 'bigint' ? value.toString() : value), 2)
          const jsonHooks = JSON.parse(bodyHooks)

          if (jsonHooks.length !== 0) {
            // Verifique se o webhook é o primeiro da lista
            if (json['webhook_id_ultima'] === null || json['webhook_id_ultima'] === undefined || jsonHooks[0]['fromMe'] === true) {
              let message = '';
              
              for (const setorBot of jsonBot[0]['setoresEscolhidos']) {
                message += `${setorBot.ordem} - ${setorBot.nome} \n`
              }
              // Primeira mensagem
              if (json['webhook_id_ultima'] === jsonHooks[0]['id'] && hooksInConversa.length === 1) {
                const sendMessageFormatted = formataMensagem(jsonBot[0]['msg_inicio'], json[0]['nome_contato'])
                const sendMessage = `${sendMessageFormatted} \n${message}`

                if(jsonBot[0].imagem) {
                  await updateDbImagem(instanceKey, contato, sendMessage, jsonBot[0].imagem)
                  await connection.queryObject`INSERT INTO "webhook"("legenda imagem", id_api_conversa, "fromMe", created_at, is_edge_function_insert, imagem, chatfire) VALUES (${sendMessage}, ${idApi}, true, NOW(), true, ${jsonBot[0].imagem}, true)`
                  return new Response('ok', { headers: corsHeaders })
                }
                await updateDb(instanceKey, contato, sendMessage)
                await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${sendMessage}, ${idApi}, true, NOW(), true, true)`
                return new Response('ok', { headers: corsHeaders })
              }

              const sendMessageFormatted = formataMensagem(jsonBot[0]['msg_inicio'], json[0]['nome_contato'])
              const sendMessage = `${sendMessageFormatted} \n${message}`
              if(jsonBot[0].imagem) {
                await updateDbImagem(instanceKey, contato, sendMessage, jsonBot[0].imagem)
                await connection.queryObject`INSERT INTO "webhook"("legenda imagem", id_api_conversa, "fromMe", created_at, is_edge_function_insert, imagem, chatfire) VALUES (${sendMessage}, ${idApi}, true, NOW(), true, ${jsonBot[0].imagem}, true)`
                const status = 'Setor'
                await connection.queryObject`UPDATE "conversas" SET "Status" = ${status}, "isforahorario" = ${false} where id = ${idConversa}`
                return new Response('ok', { headers: corsHeaders })
              }
              await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${sendMessage}, ${idApi}, true, NOW(), true, true)`
              updateDb(instanceKey, contato, sendMessage)
              const status = 'Setor'
              await connection.queryObject`UPDATE "conversas" SET "Status" = ${status}, "isforahorario" = ${false} where id = ${idConversa}`
              return new Response('ok', { headers: corsHeaders })
            }
          }
        }
        if(json[0]['Status'] == 'Setor') {
          for (const setor of jsonBot[0]['setoresEscolhidos']) {
            if (msg == setor['ordem']) {
              const espera = 'Espera'
              const setorNome = setor['nome']
              const idSetor = setor['setor']
              
              await connection.queryObject`UPDATE "conversas" SET "Setor_nomenclatura" = ${setorNome}, "Status" = ${espera}, "id_setor" = ${idSetor}, isespera = true, isforahorario = false WHERE id = ${idConversa}`
              await atendimentoTrasnferido(contato, idSetor, connection)

              const mensagemFila = formataMensagemProtocolo(jsonBot[0]['msg_fila'], json[0]['nome_contato'], idConversa)
              updateDb(instanceKey, contato, mensagemFila)
              await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${mensagemFila}, ${idApi}, true, NOW(), true, true)`
              return new Response('ok', { headers: corsHeaders })
            }
          }
          const mensagemAEnviar = 'Não entendi, escolha uma das opções abaixo, por favor'
          await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${mensagemAEnviar}, ${idApi}, true, NOW(), true, true)`
          updateDb(instanceKey, contato, mensagemAEnviar)

          let message = '';
              
          for (const setorBot of jsonBot[0]['setoresEscolhidos']) {
            message += `${setorBot.ordem} - ${setorBot.nome} \n`
          }

          const sendMessageFormatted = formataMensagem(jsonBot[0]['msg_inicio'], json[0]['nome_contato'])
          const sendMessage = `${sendMessageFormatted} \n${message}`
          await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${sendMessage}, ${idApi}, true, NOW(), true, true)`
          updateDb(instanceKey, contato, sendMessage)
          return new Response('ok', { headers: corsHeaders })
        }
      }
    } finally {
      connection.release()
      return new Response('ok', { headers: corsHeaders })
    }

    } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 400,
    })
  }

  async function updateDb(idInstancia: string, contato: string, msg: string) {
    try {
      const response = await fetch(`https://api.fireapi.com.br/message/text?key=${idInstancia}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          id: contato,
          message: msg
        })
      })

      if(!response.ok) {
        const errorData = await response.text()
        console.error('Erro na requisição:', response.status, errorData)
        return
      }

      const data = await response.json()
    } catch (error) {
      console.log(error);
    }
  }

  async function atendimentoTrasnferido(contato: string, setor: any, connection: any) {
    const result = await connection.queryObject`SELECT * FROM "Setores" WHERE id = ${setor}`
    const setorRows = result.rows;
    const body = JSON.stringify(setorRows, (key, value) => (typeof value === 'bigint' ? value.toString() : value), 2)
    const {Nome} = JSON.parse(body)[0]
    console.log({result, body, Nome})
    const mensagem = `*Atendimento transferido*\n\nSetor: ${Nome}`
    await connection.queryObject`INSERT INTO "webhook"(mensagem, id_api_conversa, "fromMe", created_at, is_edge_function_insert, chatfire) VALUES (${mensagem}, ${idApi}, true, NOW(), true, true)`
    updateDb(instanceKey, contato, mensagem)
  }

  async function updateDbImagem(idInstancia: string, contato: string, msg: string, url: string) {
    try {
      console.log({id: contato,
        url,
        type: 'image',
        caption: msg})
      const response = await fetch(`https://api.fireapi.com.br/message/mediaurl?key=${idInstancia}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          id: contato,
          url,
          type: 'image',
          caption: msg
        })
      })

      if(!response.ok) {
        const errorData = await response.text()
        console.error('Erro na requisição:', response.status, errorData)
        return
      }

      const data = await response.json()
    } catch (error) {
      console.log(error);
    }
  }
  
  function horaEstaNoIntervalo(inicio: string, fim: string): boolean {
    // Obtém a hora atual
    const agora = new Date();
    const horaAtual = agora.getHours();
    const minutosAtual = agora.getMinutes();
  
    // Converte as strings de início e fim para horas e minutos
    const partesInicio = inicio.split(":");
    const horaInicio = parseInt(partesInicio[0], 10);
    const minutosInicio = parseInt(partesInicio[1], 10);
  
    const partesFim = fim.split(":");
    const horaFim = parseInt(partesFim[0], 10);
    const minutosFim = parseInt(partesFim[1], 10);
  
    // Calcula a representação em minutos para facilitar a comparação
    const minutosAtualTotal = horaAtual * 60 + minutosAtual;
    const minutosInicioTotal = horaInicio * 60 + minutosInicio;
    const minutosFimTotal = horaFim * 60 + minutosFim;
    console.log( minutosAtualTotal >= minutosInicioTotal && minutosAtualTotal <= minutosFimTotal)
    // Verifica se a hora atual está dentro do intervalo
    return minutosAtualTotal >= minutosInicioTotal && minutosAtualTotal <= minutosFimTotal;
  }

  function formataMensagem(mensagem: string, nome: string) {
    return mensagem.replace('{{nome_cliente}}', nome)
  }

  function formataMensagemProtocolo(mensagem: string, nome: string, protocolo: string) {
    return mensagem.replace('{{nome_cliente}}', nome).replace('{{protocolo}}', protocolo)
  }
})

// To invoke:
// curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/' \
//   --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
//   --header 'Content-Type: application/json' \
//   --data '{"name":"Functions"}'
