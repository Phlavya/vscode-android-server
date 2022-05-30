const getHoras = () => {

  const clock = document.getElementsByClassName('clock')[0]

  const data = nova data()

  const horas = data.getHours()

  const minutos = data.getMinutes()

  const segundos = date.getSeconds()

  const hora = horas < 10 ? `0${horas}`: horas

  const minuto = minutos < 10 ? `0${minutos}`: minutos

  const segundo = segundos < 10 ? `0${seconds}`: segundos

  clock.innerHTML = `${hora}:${minuto}:${segundo}`

}

setInterval(() => {

  getHoras()

}, 1000)

