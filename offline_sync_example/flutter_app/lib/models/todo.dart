class Todo {

  final String id;
  final String title;
  final bool completed;
  final DateTime updatedAt;

  Todo({
    required this.id,
    required this.title,
    required this.completed,
    required this.updatedAt,
  });

  Map<String,dynamic> toJson()=>{

    "id":id,
    "title":title,
    "completed":completed,
    "updatedAt":updatedAt.toIso8601String()

  };

  factory Todo.fromJson(Map<String,dynamic> json){

    return Todo(

      id: json["id"],
      title: json["title"],
      completed: json["completed"],
      updatedAt: DateTime.parse(json["updatedAt"]),

    );

  }

}