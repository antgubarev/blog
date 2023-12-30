---
title: "Distributed locks in go without changing the app"
date: 2022-05-29
slug: distr-locks-in-go
tags: ["post"]
remote_link: https://dev.to/antgubarev/distributed-locks-in-go-without-fix-the-app-4aj8
---

Статья описывает создание консольной утилты, которая запускает приложения, но только в единственном экземпляре.
То есть не требуется менять код запускаемого приложения чтобы сделать его распределенным. Этот подход к запуску
лежит в основе и других инструментов, и основная задача как раз разобрать как он работает.
