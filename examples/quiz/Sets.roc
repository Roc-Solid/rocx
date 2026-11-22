import pf.Db
import Draft
import Game

## Question sets, in Postgres (`migrations/`): the ones the app seeds, and the ones made in the
## editor. Server-only: it imports `Db`.
Sets := [].{

	## A set, as the host's list shows it.
	Summary : { id : I64, title : Str, blurb : Str, questions : I64 }

	## Every set, the newest made first, then the seeded ones in the order they were seeded.
	all! : {} => Try(List(Sets.Summary), [DbErr(Str), BadRow(Str)])
	all! = |{}|
		Db.all!(
			"select s.id, s.title, s.blurb, count(q.position)::int8 as questions from quiz_sets s left join quiz_questions q on q.set_id = s.id group by s.id order by s.slug is not null, s.created_at desc, s.id",
			[],
		)

	## Set `id`'s title and questions, in order.
	load! : I64 => Try({ title : Str, questions : List(Game.Question) }, [NotFound, DbErr(Str), BadRow(Str)])
	load! = |id| {
		titled : List({ title : Str })
		titled = Db.all!("select title from quiz_sets where id = $1", [Int(id)])?
		match titled {
			[set, ..] => {
				questions : List(Game.Question)
				questions = Db.all!("select prompt, choices, answer from quiz_questions where set_id = $1 order by position", [Int(id)])?
				Ok({ title: set.title, questions })
			}
			[] => Err(NotFound)
		}
	}

	## A new set, written in one transaction: its id.
	create! : Draft.Made => Try(I64, [DbErr(Str), BadRow(Str)])
	create! = |made|
		Db.transaction!(
			|{}| {
				ids : List({ id : I64 })
				ids = Db.all!("insert into quiz_sets (title, blurb) values ($1, $2) returning id", [Text(made.title), Text(made.blurb)])?
				id = (ids.first() ?? { id: 0 }).id
				for (asked, at) in made.questions.map_with_index(|asked, at| (asked, at)) {
					_ = Db.run!(
						"insert into quiz_questions (set_id, position, prompt, choices, answer) values ($1, $2, $3, $4::jsonb, $5)",
						[Int(id), Int(at.to_i64_wrap()), Text(asked.prompt), Text(Json.to_str(asked.choices)), Int(asked.answer.to_i64_wrap())],
					)?
				}
				Ok(id)
			},
		)
}
