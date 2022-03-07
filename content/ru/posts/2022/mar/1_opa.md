---
title: Собственные built-in функции в rego 
date: "2022-03-07"
keywords: "openpolicyagent, OPA, built-in"
description: "расширение rego своими функциями"
---

Что это такое Open Policy Agent (OPA) и с чем его едят уже прекрасно описано в [этой статье](https://habr.com/ru/post/555538/). 
И не менее подробно в [официальной документации](https://www.openpolicyagent.org/docs/latest/). 
Переписывать все это другими словами полезности никакой. Однако при внедрении этой штуки на проекте 
столкнулся с недостатком описания и примеров по [built-in функциям](https://www.openpolicyagent.org/docs/latest/extensions/). 
Немного заполню этот пробел.

Я внедрял OPA для авторизации на ручках в API. Требовалось на основе привязки пользователей к группам (читай командам, юнитам
и т.д.) разрешать или нет какие-то действия. В реальности в политиках принимало участие гораздо большее количество факторов,
но в рамках текущей темы это значения не имеет. 

Итак, допустим у нас есть какая-то структура групп и пользователи, которые могут состоять сразу в нескольких группах
одновременно. Причем сами группы также имеют связи "many-to-many".

![structure](/ru/posts/2022/mar/structure.drawio.svg)

Структура выше разумеется выдуманная. Как видно один из разработчиков прикреплен сразу к двум командам. 
Изначально он работал в команде биллинга, но имел навыки devops и захотел дальше развиваться в этом направлении.
Также есть команда SWAT, которая призвана тушить пожары и помогать другим командам вывозить требуемые объемы в нужные сроки,
поэтому она является частью двух других групп.

И есть два действия в системе: 
- cordon - кордонить ноду
- deploy - деплоить приложение в прод
Действия привязаны к группам, а также распространяются на все дочерние группы. 
Задача написать правилa для OPA.

Для решения сначала потребуется орг структура в json формате для использования в rego правилах. Примерно так:

```json
{
    "users": [
        {
            "id": "ivanov",
            "groups": ["billing"]
        },
        {
            "id": "petrov",
            "groups": ["swat"]
        },
    ],
    "groups": [
        {
            "id": "infra",
            "parent": []
        },
        {
            "id": "devops",
            "parent": ["infra"]
        },
        {
            "id": "admin",
            "parent": ["infra"]
        },
        {
            "id": "dev",
            "parent": []
        },
        {
            "id": "search",
            "parent": ["dev"]
        },
        {
            "id": "billing",
            "parent": ["dev"]
        },
        {
            "id": "swat",
            "parent": ["infra", "billing"]
        },
    ],
}
```

Поскольку правила прибиты к группам, то достаточно проверять состоит ли пользователь в нужной группе или нет. 
А также является ли группа пользователя подгруппой другой группы с нужными правами (на любом уровне вложенности).
Тут как раз возникла проблема. Если рекурсию сделать на Rego (не уверен, что это вообще возможно), то читаемость
будет мягко говоря не очень. Готовых функций тоже нет. Но к счастью существует возможность расширять Rego своими 
функциями. 

Вот так выглядит реализация непосредственно самой кастомной функции:

```golang
// search all group parents
func RegoGroupParentsFunction() func(*rego.Rego) {
	return rego.Function2(&rego.Function{
		Name: "group_parents",
		Decl: types.NewFunction(types.Args(types.S, types.A), types.A),
	},
		func(bctx rego.BuiltinContext, groupID, groupsData *ast.Term) (*ast.Term, error) {
			groups := []Group{}
			if err := json.Unmarshal([]byte(groupsData.Value.String()), &groups); err != nil {
				return nil, fmt.Errorf("unmarshal rego groups data: %v", err)
			}

			mappedGroups := map[string]*Group{}
			for k, group := range groups {
				mappedGroups[group.ID] = &groups[k]
			}

			gID := trimDoubleQuotes(groupID.Value.String())
			parentGroups := []*Group{}
			SearchParentsRecursive(gID, mappedGroups, &parentGroups)

			values := []*ast.Term{}
			for _, v := range parentGroups {
				val, err := ast.InterfaceToValue(v)
				if err != nil {
					return nil, fmt.Errorf("convert group to rego value: %v", err)
				}
				values = append(values, ast.NewTerm(val))
			}

			return ast.ArrayTerm(values...), nil
		})
}

func SearchParentsRecursive(groupID string, groups map[string]*Group, result *[]*Group) {
	group, ok := groups[groupID]
	if !ok {
		return
	}
	if len(group.Parents) == 0 {
		return
	}
	for _, parentID := range group.Parents {
		parentGroup, ok := groups[parentID]
		if !ok {
			continue
		}
		SearchParentsRecursive(parentID, groups, result)
		*result = append(*result, parentGroup)
	}
}
```

Опишу что здесь происходит.

```golang
	return rego.Function2(&rego.Function{
		Name: "group_parents",
		Decl: types.NewFunction(types.Args(types.S, types.A), types.A),
	},
		func(bctx rego.BuiltinContext, groupID, groupsData *ast.Term) (*ast.Term, error) {
```

Объявляется новая функция `group_parents`, которая будет принимать два аргумента: id группы, которую ищем, и структура с группами, описанная выше.
Соответственно для rego функций с тремя аргументами есть функция Function3, с четырьмя Function4 и т.д. 

Далее парсится json со структурой и происходит рекурсивный поиск по всем родителям. Сложности появляются при возврате результата,
так как итерфейс у библотеки не очень очевидный.

```golang
values := []*ast.Term{}
for _, v := range parentGroups {
	val, err := ast.InterfaceToValue(v)
	if err != nil {
		return nil, fmt.Errorf("convert group to rego value: %v", err)
	}
	values = append(values, ast.NewTerm(val))
}

return ast.ArrayTerm(values...), nil

```

Функция должна вернуть массив со всеми родительскими группами, чтобы по нему уже пройтись в самих правилах. 
Поэтому мы возвращаем `ast.ArrayTerm`. Это массив регошных значений (Term), которые надо предварительно 
создать с помощью `ast.NewTerm`. А перед этим также потребуется конвертировать строковые значения с id групп
`ast.InterfaceToValue`.     

Теперь `group_parents` доступна в политиках rego. Покажу как это работает:

```rego
package group_search

import future.keywords.in

default parent_groups_is_ok = false

# Проверяем что группа SWAT состоит во всех вышестоящих группах billing и devops
parent_groups_is_ok {
   groups := group_parents("swat", data.groups)

   groups[0].name == "billing"
   groups[1].name == "devops"
}

# Убеждаемся что в лишних группах swat нет
parent_groups_not_exists {
   groups := group_parents("swat", data.groups)
   groups[_].name != "search"
}
```

Теперь можно написать тест и проверить

```golang

func TestGroupParentsOk(t *testing.T) {
   query, err := rego.New(
      rego.Query("data.group_search.parent_groups_is_ok"),
      RegoGroupParentsFunction()
      rego.LoadBundle("testdata"),
   ).PrepareForEval(context.Background())
   if err != nil {
      t.Fatalf("prepare rego query: %v", err)
   }

   resultSet, err := query.Eval(context.Background())
   if err != nil {
      t.Fatalf("eval rego query: %v", err)
   }

   if len(resultSet) == 0 {
      t.Error("undefined result")
   }

   assert.True(t, resultSet.Allowed())
}

func TestGroupParentsNotExist(t *testing.T) {
   query, err := rego.New(
      rego.Query("data.group_search.runtime_parent_groups_not_exists"),
      RegoGroupParentsFunction(),
      rego.LoadBundl("testdata"),
   ).PrepareForEval(context.Background())
   if err != nil {
      t.Fatalf("prepare rego query: %v", err)
   }

   resultSet, err := query.Eval(context.Background())
   if err != nil {
      t.Fatalf("eval rego query: %v", err)
   }

   if len(resultSet) == 0 {
      t.Error("undefined result")
   }

   assert.True(t, resultSet.Allowed())
}
```

Таким образом возможно расширять rego сколь угодно много. Например добавить работу с какими-то внешними 
источниками: базами данных, апишками и т.д. Или как в моем случае реализовать сложную логику.
