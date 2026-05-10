/// <reference path="../pb_data/types.d.ts" />
migrate((app) => {
  const collection = app.findCollectionByNameOrId("pbc_2777700647")

  // add field
  collection.fields.addAt(6, new Field({
    "help": "",
    "hidden": false,
    "id": "number1205073554",
    "max": null,
    "min": null,
    "name": "questionCount",
    "onlyInt": false,
    "presentable": false,
    "required": false,
    "system": false,
    "type": "number"
  }))

  // add field
  collection.fields.addAt(7, new Field({
    "help": "",
    "hidden": false,
    "id": "number1685056229",
    "max": null,
    "min": null,
    "name": "timeLimitSeconds",
    "onlyInt": false,
    "presentable": false,
    "required": false,
    "system": false,
    "type": "number"
  }))

  // add field
  collection.fields.addAt(8, new Field({
    "help": "",
    "hidden": false,
    "id": "json3884348916",
    "maxSize": 2000000,
    "name": "threadMessages",
    "presentable": false,
    "required": false,
    "system": false,
    "type": "json"
  }))

  return app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("pbc_2777700647")

  // remove field
  collection.fields.removeById("number1205073554")

  // remove field
  collection.fields.removeById("number1685056229")

  // remove field
  collection.fields.removeById("json3884348916")

  return app.save(collection)
})
