let uncapitalize = str =>
  switch String.get(str, 0) {
  | None => ""
  | Some(first) => String.concat(first->String.toLowerCase, String.slice(str, ~start=1))
  }

let getItemById = `
  {
    "version": "2017-02-28",
    "operation": "GetItem",
    "key": {
        "id": $util.dynamodb.toDynamoDBJson($ctx.args.id),
    }
  }
  `->Pulumi.Input.make

let queryById = `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "id = :id",
        "expressionValues" : {
            ":id" : $util.dynamodb.toDynamoDBJson($context.arguments.id)
        }
    }
  }
  `->Pulumi.Input.make

let queryByIdSort = (sortField: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "id = :id AND #${sortField} = :${sortField}",
        "expressionNames" : {
            "#${sortField}" : "${sortField}"
        },
       "expressionValues" : {
            ":id" : $util.dynamodb.toDynamoDBJson($context.arguments.id),
            ":${sortField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${sortField})
        }
    }
  }
  `->Pulumi.Input.make

let queryByIndex = (index: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "#${index} = :${index}",
        "expressionNames" : {
            "#${index}" : "${index}"
        },
       "expressionValues" : {
            ":${index}" : $util.dynamodb.toDynamoDBJson($context.arguments.${index})
        }
    },
    "index" : "${index}"
  }
  `->Pulumi.Input.make

let queryByIndexDeletable = (index: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "#${index} = :${index}",
        "expressionNames" : {
            "#${index}" : "${index}"
        },
       "expressionValues" : {
            ":${index}" : $util.dynamodb.toDynamoDBJson($context.arguments.${index})
        }
    },
    #if($context.arguments.hideDeleted)
   "filter": {
        "expression": "#deleted = :false",
        "expressionNames" : {
            "#deleted" : "deleted"
        },
       "expressionValues" : {
            ":false" : $util.dynamodb.toDynamoDBJson(false)
        }
    },
    #end
    "index" : "${index}"
  }
  `->Pulumi.Input.make

let queryByIndexSort = (~index: string, ~idField: string, ~sortField: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
  #if($context.arguments.${sortField})
        "expression" : "#${idField} = :${idField} AND #${sortField} = :${sortField}",
        "expressionNames" : {
            "#${idField}" : "${idField}",
            "#${sortField}" : "${sortField}"
        },
       "expressionValues" : {
            ":${idField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${idField}),
            ":${sortField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${sortField})
        }
  #else
        "expression" : "#${idField} = :${idField}",
        "expressionNames" : {
            "#${idField}" : "${idField}"
        },
       "expressionValues" : {
            ":${idField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${idField})
        }
  #end
    },
    "index" : "${index}"
  }
  `->Pulumi.Input.make

let queryByIndexFiltered = (~index: string, ~idField: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "#${idField} = :${idField}",
        "expressionNames" : {
            "#${idField}" : "${idField}"
        },
       "expressionValues" : {
            ":${idField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${idField})
        }
    },
    #set($expression = "")
    #set($names = {})
    #set($values = {})
    #foreach($filter in $context.arguments.entrySet())
      #set($key = $filter.key)
      #set($value = $filter.value)
      #if($key != "${idField}" && $key != "limit" && $key != "nextToken" &&
      	$key != "forward" && !$util.isNullOrBlank($filter.value))
        #if($expression != "")
          #set($expression = "$expression AND")
        #end
        #if($key == "hideDeleted")
          #if($value == true)
            #set($expression = "$expression #deleted = :false")
            $util.qr($names.put("#deleted", "deleted"))
            $util.qr($values.put(":false", false))
          #end
        #elseif($util.isList($value))
          $util.qr($names.put("#$key", "$key"))
          #foreach($item in $value)
            #if($expression != "" && !$expression.endsWith("AND"))
              #set($expression = "$expression AND")
            #end
            #set($expression = "$expression contains(#$key, :$item)" )
            $util.qr($values.put(":$item", "$item"))
          #end
        #else
          #set($expression = "$expression contains(#$key, :$key)" )
          $util.qr($names.put("#$key", "$key"))
          $util.qr($values.put(":$key", "$value"))
        #end
      #end
    #end
    #if($expression != "")
      "filter": {
          "expression": "$expression",
          "expressionNames" : $util.toJson($names),
          "expressionValues" : $util.dynamodb.toMapValuesJson($values)
      },
    #end
    "index" : "${index}",
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  `->Pulumi.Input.make

let queryByIndexSortFiltered = (~index: string, ~idField: string, ~sortField: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
  #if($context.arguments.${sortField})
        "expression" : "#${idField} = :${idField} AND #${sortField} = :${sortField}",
        "expressionNames" : {
            "#${idField}" : "${idField}",
            "#${sortField}" : "${sortField}"
        },
       "expressionValues" : {
            ":${idField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${idField}),
            ":${sortField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${sortField})
        }
  #else
        "expression" : "#${idField} = :${idField}",
        "expressionNames" : {
            "#${idField}" : "${idField}"
        },
       "expressionValues" : {
            ":${idField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${idField})
        }
  #end
    },
    #set($expression = "")
    #set($names = {})
    #set($values = {})
    #foreach($filter in $context.arguments.entrySet())
      #set($key = $filter.key)
      #set($value = $filter.value)
      #if($key != "${idField}" && $key != "${sortField}" && $key != "limit" && $key != "nextToken" &&
      	$key != "forward" && !$util.isNullOrBlank($filter.value))
        #if($expression != "")
          #set($expression = "$expression AND")
        #end
        #if($key == "hideDeleted")
          #if($value == true)
            #set($expression = "$expression #deleted = :false")
            $util.qr($names.put("#deleted", "deleted"))
            $util.qr($values.put(":false", false))
          #end
        #elseif($util.isList($value))
          $util.qr($names.put("#$key", "$key"))
          #foreach($item in $value)
            #if($expression != "" && !$expression.endsWith("AND"))
              #set($expression = "$expression AND")
            #end
            #set($expression = "$expression contains(#$key, :$item)" )
            $util.qr($values.put(":$item", "$item"))
          #end
        #else
          #set($expression = "$expression contains(#$key, :$key)" )
          $util.qr($names.put("#$key", "$key"))
          $util.qr($values.put(":$key", "$value"))
        #end
      #end
    #end
    #if($expression != "")
      "filter": {
          "expression": "$expression",
          "expressionNames" : $util.toJson($names),
          "expressionValues" : $util.dynamodb.toMapValuesJson($values)
      },
    #end
    "index" : "${index}",
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  `->Pulumi.Input.make

let authorizeIndexedAccessRequest = (~index: string, ~group: string) => {
  let authIdName = group->uncapitalize ++ "Id"
  `
    #foreach($group in $context.identity.claims.get("cognito:groups"))
      #if($group == "${group}")
          #set($is${group} = true)
      #end
    #end
    #if($is${group})
      {
        "operation": "GetItem",
        "key": {
          "id": $util.dynamodb.toDynamoDBJson($ctx.args.${index}),
        }
      }
    #else
    	#return({"${authIdName}": [$ctx.identity.username]})
    #end
  `->Pulumi.Input.make
}

let authorizeIndexedAccessResponse = (~group: string) => {
  let authIdName = group->uncapitalize ++ "Id"
  `
    #if($ctx.error)
      $util.error($ctx.error.message, $ctx.error.type)
    #end

    #if($ctx.result.${authIdName} == $ctx.identity.username)
    	$util.toJson($ctx.result)
    #else
    	$util.unauthorized()
    #end
  `->Pulumi.Input.make
}

let listAllItems = `
  {
    "version" : "2017-02-28",
    "operation" : "Scan",
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null))
  }
  `->Pulumi.Input.make

let resolveId = (~sourceIdField: string) =>
  `
  #if( $ctx.source.${sourceIdField} )
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "#id = :id",
        "expressionNames" : {
            "#id" : "id"
        },
       "expressionValues" : {
            ":id" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField})
        }
    },
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  #else
    #return
  #end
  `->Pulumi.Input.make

let resolveIdSort = (~sourceIdField: string, ~sourceSortField: string, ~targetSortField: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "#id = :id AND #${targetSortField} = :${targetSortField}",
        "expressionNames" : {
            "#id" : "id",
            "#${targetSortField}" : "${targetSortField}"
        },
       "expressionValues" : {
            ":id" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField}),
            ":${targetSortField}" : $util.dynamodb.toDynamoDBJson($context.source.${sourceSortField})
        }
    },
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  `->Pulumi.Input.make

let resolveIdSortArgument = (
  ~sourceIdField: string,
  ~sourceSortArgument: string,
  ~targetSortField: string,
) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
  #if($context.arguments.${sourceSortArgument})
        "expression" : "#id = :id AND #${targetSortField} = :${targetSortField}",
        "expressionNames" : {
            "#id" : "id",
            "#${targetSortField}" : "${targetSortField}"
        },
       "expressionValues" : {
            ":id" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField}),
            ":${targetSortField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${sourceSortArgument})
        }
  #else
        "expression" : "#id = :id",
        "expressionNames" : {
            "#id" : "id"
        },
       "expressionValues" : {
            ":id" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField})
        }
  #end
    },
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  `->Pulumi.Input.make

let resolveIdByIndex = (~index: string, ~sourceIdField: string, ~targetIdField: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "#${targetIdField} = :${targetIdField}",
        "expressionNames" : {
            "#${targetIdField}" : "${targetIdField}"
        },
       "expressionValues" : {
            ":${targetIdField}" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField})
        }
    },
    "index" : "${index}",
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  `->Pulumi.Input.make

let resolveIdByIndexSort = (
  ~index: string,
  ~sourceIdField: string,
  ~sourceSortField: string,
  ~targetIdField: string,
  ~targetSortField: string,
) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
        "expression" : "#${targetIdField} = :${targetIdField} AND #${targetSortField} = :${targetSortField}",
        "expressionNames" : {
            "#${targetIdField}" : "${targetIdField}",
            "#${targetSortField}" : "${targetSortField}"
        },
       "expressionValues" : {
            ":${targetIdField}" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField}),
            ":${targetSortField}" : $util.dynamodb.toDynamoDBJson($context.source.${sourceSortField})
        }
    },
    "index" : "${index}",
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  `->Pulumi.Input.make

let resolveIdByIndexSortArgument = (
  ~index: string,
  ~sourceIdField: string,
  ~sourceSortArgument: string,
  ~targetIdField: string,
  ~targetSortField: string,
) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "Query",
    "query" : {
  #if($context.arguments.${sourceSortArgument})
        "expression" : "#${targetIdField} = :${targetIdField} AND #${targetSortField} = :${targetSortField}",
        "expressionNames" : {
            "#${targetIdField}" : "${targetIdField}",
            "#${targetSortField}" : "${targetSortField}"
        },
       "expressionValues" : {
            ":${targetIdField}" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField}),
            ":${targetSortField}" : $util.dynamodb.toDynamoDBJson($context.arguments.${sourceSortArgument})
        }
  #else
        "expression" : "#${targetIdField} = :${targetIdField}",
        "expressionNames" : {
            "#${targetIdField}" : "${targetIdField}"
        },
       "expressionValues" : {
            ":${targetIdField}" : $util.dynamodb.toDynamoDBJson($context.source.${sourceIdField})
        }
  #end
    },
    "index" : "${index}",
    "limit": $util.defaultIfNull($context.arguments.limit, 50),
    "nextToken": $util.toJson($util.defaultIfNullOrBlank($context.arguments.nextToken, null)),
    "scanIndexForward": $util.defaultIfNull($context.arguments.forward, true)
  }
  `->Pulumi.Input.make

let resolveIds = (tableName: string, ~idsField: string, ~sortField: option<string>) => {
  let insertSortField = switch sortField {
  | Some(sortField) =>
    `
      $util.qr($map.put("id", $util.dynamodb.toString($id.id)))
      $util.qr($map.put("${sortField}", $util.dynamodb.toString($id.${sortField})))
      `
  | None => `$util.qr($map.put("id", $util.dynamodb.toString($id)))`
  }
  `
  #set($idList = $ctx.source.${idsField})
  #if(! $idList.isEmpty() )
    #set($ids = [])
    #foreach($id in $idList)
        #set($map = {})
        ${insertSortField}
        $util.qr($ids.add($map))
    #end
    {
      "version" : "2018-05-29",
      "operation" : "BatchGetItem",
      "tables" : {
          "${tableName}": {
              "keys": $util.toJson($ids),
              "consistentRead": true
          }
      }
    }
  #else
    {
      "version": "2017-02-28",
      "operation": "GetItem",
      "key": {
          "id": $util.dynamodb.toDynamoDBJson($ctx.source.id),
      }
    }
  #end
  `
}

let putItem = `
  {
    "version" : "2017-02-28",
    "operation" : "PutItem",
    "key" : {
        "id": $util.dynamodb.toDynamoDBJson($ctx.args.id),
    },
    "attributeValues" : $util.dynamodb.toMapValuesJson($ctx.args)
  }
  `->Pulumi.Input.make

let addItemToList = (~listName: string, ~itemName: string) =>
  `
  {
    "version" : "2017-02-28",
    "operation" : "UpdateItem",
    "key" : {
        "id": $util.dynamodb.toDynamoDBJson($ctx.args.id),
    },
    "update" : {
      "expression": "SET #list = list_append(#list, :item)",
      "expressionNames": {
            "#list" : "${listName}"
        },
      "expressionValues": {
          ":item" : $util.dynamodb.toDynamoDBJson([$ctx.args.${itemName}])
      }
    }
  }
  `->Pulumi.Input.make

let deleteItem = `
  {
    "version" : "2017-02-28",
    "operation" : "DeleteItem",
    "key" : {
        "id" : { "S" : "$ctx.args.id" }
    }
  }
  `->Pulumi.Input.make

let result = "$util.toJson($ctx.result)"->Pulumi.Input.make

let firstResult = `
  #if( $ctx.result.items.isEmpty() )
    $util.toJson(null)
  #else
    $util.toJson($ctx.result.items[0])
  #end
  `->Pulumi.Input.make

let resultList = "$util.toJson($ctx.result.items)"->Pulumi.Input.make

let resolveIdResult = (tableName: string, ~idField: string) =>
  `
  #if( $ctx.source.${idField} )
    $util.toJson($ctx.result.data.${tableName}[0])
  #else
    $util.toJson(null)
  #end
  `->Pulumi.Input.make

let resolveIdResults = (tableName: string, ~idField: string) =>
  `
  #if( $ctx.source.${idField} )
    $util.toJson($ctx.result.data.${tableName})
  #else
    $util.toJson(null)
  #end
  `

let resolveIdsResult = (tableName: string, ~idsField: string) =>
  `
  #set($idList = $ctx.source.${idsField})
  #if(! $idList.isEmpty() )
    $util.toJson($ctx.result.data.${tableName})
  #else
    $util.toJson([])
  #end
  `

let null = "$util.toJson(null)"->Pulumi.Input.make
