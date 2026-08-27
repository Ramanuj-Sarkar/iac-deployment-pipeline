def _create(client, **body):
    body.setdefault("title", "write tests")
    return client.post("/todos", json=body)


def test_health_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok", "database": "ok"}


def test_create_and_fetch(client):
    resp = _create(client, title="buy milk", description="2%")
    assert resp.status_code == 201
    todo = resp.get_json()
    assert todo["title"] == "buy milk"
    assert todo["completed"] is False
    assert todo["id"]

    got = client.get(f"/todos/{todo['id']}")
    assert got.status_code == 200
    assert got.get_json()["description"] == "2%"


def test_create_rejects_bad_body(client):
    assert _create(client, title="").status_code == 400
    assert client.post("/todos", json={"nope": 1}).status_code == 400
    assert _create(client, extra="x").status_code == 400


def test_list_filters_and_paginates(client):
    for i in range(3):
        _create(client, title=f"todo {i}")
    done = _create(client, title="done one").get_json()
    client.patch(f"/todos/{done['id']}", json={"completed": True})

    resp = client.get("/todos")
    body = resp.get_json()
    assert body["total"] == 4
    assert len(body["items"]) == 4

    resp = client.get("/todos?completed=true")
    body = resp.get_json()
    assert body["total"] == 1
    assert body["items"][0]["title"] == "done one"

    resp = client.get("/todos?limit=2&offset=0")
    assert len(resp.get_json()["items"]) == 2
    assert client.get("/todos?completed=maybe").status_code == 400


def test_patch_updates_subset(client):
    todo = _create(client, title="original").get_json()
    resp = client.patch(f"/todos/{todo['id']}", json={"title": "renamed"})
    assert resp.status_code == 200
    updated = resp.get_json()
    assert updated["title"] == "renamed"
    assert updated["updated_at"] >= todo["updated_at"]

    assert client.patch(f"/todos/{todo['id']}", json={}).status_code == 400


def test_delete(client):
    todo = _create(client).get_json()
    assert client.delete(f"/todos/{todo['id']}").status_code == 204
    assert client.get(f"/todos/{todo['id']}").status_code == 404


def test_unknown_id_is_404(client):
    assert client.get("/todos/not-a-uuid").status_code == 404
    assert client.get("/todos/11111111-1111-1111-1111-111111111111").status_code == 404
