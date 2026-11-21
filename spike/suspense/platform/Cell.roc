import Host

## A typed cell the host keeps: the type is fixed when it is made, so reading it back is sound.
Cell(a) :: { id : U64 }.{
	new! : a => Cell(a)
	new! = |value| { id: Host.cell_new!(Box.box(value)) }

	get! : Cell(a) => a
	get! = |cell| Box.unbox(Host.cell_get!(cell.id))
}
